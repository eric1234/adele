import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/application_plugin_bootstrap.dart';
import 'package:adele_desktop/core/environment_capability_invocation.dart';
import 'package:adele_desktop/core/environment_capability_selection.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';

final _capability = CapabilityKey(
  id: CapabilityId('test.environment-callable'),
  majorVersion: 1,
);
final _otherCapability = CapabilityKey(
  id: CapabilityId('test.other-callable'),
  majorVersion: 1,
);

void main() {
  test(
    'capture is synchronous, canonical, lazy, and not Task-primary',
    () async {
      final fixture = _Fixture();
      final captured = fixture.capture();
      expect(captured.session, same(fixture.session));
      expect(captured.environment, same(fixture.additional));
      expect(fixture.resolutions, 0);
      expect(fixture.selections, 0);
      expect(fixture.additionalProvider.restored, isEmpty);
      expect(
        fixture.runtime.currentMaterialization(fixture.additional.id),
        isNull,
      );

      final selection = await captured.resolve(_capability);
      expect(selection.session, same(fixture.session));
      expect(selection.environment, same(fixture.additional));
      expect(selection.binding.isSameRegistration(fixture.callable), isTrue);
      expect(
        selection.materialization,
        same(fixture.runtime.currentMaterialization(fixture.additional.id)),
      );
      expect(
        selection.materialization.binding.isSameRegistration(fixture.anchor),
        isTrue,
      );
      expect(fixture.additionalProvider.restored, [fixture.additional.id]);
      expect(fixture.primaryProvider.restored, isEmpty);
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
      selection.validate();
    },
  );

  test('unknown and lookalike Sessions fail before any provider work', () {
    final fixture = _Fixture();
    for (final id in [fixture.session.id, SessionId('unknown')]) {
      expect(
        () => fixture.capture(
          session: Session(
            id: id,
            taskId: fixture.session.taskId,
            strategyId: fixture.session.strategyId,
          ),
        ),
        throwsArgumentError,
      );
    }
    expect(fixture.resolutions, 0);
    expect(fixture.selections, 0);
  });

  test(
    'invalid restored authority graphs cannot become canonical captures',
    () {
      final fixture = _Fixture();
      final otherTask = Task(
        id: TaskId('other-task'),
        projectId: fixture.task.projectId,
        title: 'Other',
      );
      final foreignEnvironment = Environment(
        id: EnvironmentId('other-task-environment'),
        taskId: otherTask.id,
        role: EnvironmentRole.primary,
        providerId: fixture.primary.providerId,
        providerState: const {},
      );
      for (final graph in [
        (
          tasks: <Task>[],
          environments: [fixture.primary],
          authorities: [(fixture.session.id, fixture.primary.id)],
        ),
        (
          tasks: [fixture.task],
          environments: [fixture.primary],
          authorities: [(fixture.session.id, fixture.additional.id)],
        ),
        (
          tasks: [fixture.task, otherTask],
          environments: [fixture.primary, foreignEnvironment],
          authorities: [(fixture.session.id, foreignEnvironment.id)],
        ),
        (
          tasks: [fixture.task],
          environments: [fixture.primary],
          authorities: <(SessionId, EnvironmentId)>[],
        ),
      ]) {
        final store = InMemoryProductStore();
        expect(
          () => store.publishRestoredProject(
            project: fixture.project,
            tasks: graph.tasks,
            environments: graph.environments,
            sessions: [fixture.session],
            authorities: graph.authorities,
            runRecords: const [],
          ),
          throwsStateError,
        );
        final runtime = EnvironmentRuntime(
          store: store,
          registry: fixture.registry,
          providerForBinding: (_) => throw StateError('Must not resolve.'),
          retainEnvironment: store.replaceEnvironment,
        );
        expect(
          () => CapturedEnvironmentCapabilities.withResolvers(
            environmentRuntime: runtime,
            session: fixture.session,
            resolveAssociatedProvider: fixture.select,
            associationFor: fixture.associationFor,
          ),
          throwsArgumentError,
        );
        expect(store.session(fixture.session.id), isNull);
        expect(store.project(fixture.project.id), isNull);
      }
      expect(fixture.resolutions, 0);
      expect(fixture.selections, 0);
    },
  );

  test(
    'navigation and another Session cannot redirect held materialization',
    () async {
      final fixture = _Fixture();
      var selected = fixture.session;
      final captured = fixture.capture(session: selected);
      selected = fixture.otherSession;
      final restoring = Completer<EnvironmentProviderResult>();
      fixture.additionalProvider.restoration = restoring.future;
      final first = captured.resolve(_capability);
      final repeated = captured.resolve(_capability);
      final other = await fixture
          .capture(session: selected)
          .resolve(_capability);
      expect(other.environment, same(fixture.primary));
      expect(other.binding.isSameRegistration(fixture.primaryCallable), isTrue);
      expect(fixture.additionalProvider.restored, [fixture.additional.id]);
      expect(fixture.selections, 1);
      selected = fixture.session;
      restoring.complete(
        EnvironmentProviderResult(providerState: {'ready': true}),
      );

      final result = await first;
      expect(await repeated, same(result));
      expect(result.environment, same(fixture.additional));
      expect(result.materialization.environment.id, fixture.additional.id);
      expect(result.binding.isSameRegistration(fixture.callable), isTrue);
      expect(selected, same(fixture.session));
      expect(fixture.selections, 2);
      expect(fixture.resolutions, 2);
    },
  );

  test('different selections share one lazy materialization', () async {
    final fixture = _Fixture();
    fixture.registerCallable(
      'test.other-callable',
      fixture.anchor,
      capability: _otherCapability,
    );
    final restoring = Completer<EnvironmentProviderResult>();
    fixture.additionalProvider.restoration = restoring.future;
    final captured = fixture.capture();
    final first = captured.resolve(_capability);
    final other = captured.resolve(_otherCapability);
    expect(fixture.resolutions, 1);
    expect(fixture.selections, 0);
    restoring.complete(
      EnvironmentProviderResult(providerState: {'ready': true}),
    );
    expect((await first).materialization, same((await other).materialization));
    expect(fixture.additionalProvider.restored, hasLength(1));
  });

  test('failed materialization is sticky across selection requests', () async {
    final fixture = _Fixture();
    const failure = EnvironmentFailure(
      code: 'restore_failed',
      message: 'No state.',
      details: {},
    );
    fixture.additionalProvider.restoreFailure = failure;
    final captured = fixture.capture();
    await expectLater(captured.resolve(_capability), throwsA(same(failure)));
    fixture.additionalProvider.restoreFailure = null;
    await expectLater(
      captured.resolve(_otherCapability),
      throwsA(same(failure)),
    );
    await expectLater(
      captured.resolve(_capability, providerId: fixture.callable.provider.id),
      throwsA(same(failure)),
    );
    expect(fixture.additionalProvider.restored, hasLength(1));
    expect(fixture.resolutions, 1);
    expect(fixture.selections, 0);
  });

  test(
    'missing recorded Environment provider never substitutes or retries',
    () async {
      final fixture = _Fixture();
      await fixture.registrations[fixture.anchor]!.close();
      final captured = fixture.capture();
      await expectLater(
        captured.resolve(_capability),
        throwsA(isA<ProviderUnavailable>()),
      );
      final replacement = _Provider(fixture.additional.providerId);
      fixture.registerEnvironment(replacement);
      await expectLater(
        captured.resolve(_otherCapability),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(replacement.restored, isEmpty);
      expect(fixture.primaryProvider.restored, isEmpty);
      expect(fixture.selections, 0);
    },
  );

  test(
    'Environment retirement and replacement cannot retarget capture or result',
    () async {
      final fixture = _Fixture();
      final captured = fixture.capture();
      final selection = await captured.resolve(_capability);
      await fixture.registrations[fixture.anchor]!.close();
      final replacement = _Provider(fixture.additional.providerId);
      final replacementAnchor = fixture.registerEnvironment(replacement);
      fixture.associations[fixture.callable] = replacementAnchor;
      final fresh = await fixture.capture().resolve(_capability);
      expect(
        fresh.materialization.binding.isSameRegistration(replacementAnchor),
        isTrue,
      );
      expect(() => selection.validate(), throwsA(_stale));
      await expectLater(captured.resolve(_capability), throwsA(_stale));
      await expectLater(captured.resolve(_otherCapability), throwsA(_stale));
      expect(replacement.restored, [fixture.additional.id]);
      expect(fixture.resolutions, 2);
    },
  );

  test(
    'retirement during restoration fails permanently without selection',
    () async {
      final fixture = _Fixture();
      final restoring = Completer<EnvironmentProviderResult>();
      fixture.additionalProvider.restoration = restoring.future;
      final captured = fixture.capture();
      final pending = expectLater(
        captured.resolve(_capability),
        throwsA(_stale),
      );
      await fixture.registrations[fixture.anchor]!.close();
      final replacement = _Provider(fixture.additional.providerId);
      fixture.registerEnvironment(replacement);
      restoring.complete(
        EnvironmentProviderResult(providerState: {'ready': true}),
      );
      await pending;
      await expectLater(captured.resolve(_otherCapability), throwsA(_stale));
      expect(replacement.restored, isEmpty);
      expect(fixture.selections, 0);
    },
  );

  test(
    'callable retirement and replacement cannot retarget a retained selection',
    () async {
      final fixture = _Fixture();
      final captured = fixture.capture();
      final selection = await captured.resolve(_capability);
      await fixture.registrations[fixture.callable]!.close();
      final replacement = fixture.registerCallable(
        fixture.callable.provider.id.value,
        fixture.anchor,
      );
      expect(() => selection.validate(), throwsA(_stale));
      await expectLater(captured.resolve(_capability), throwsA(_stale));
      expect(fixture.selections, 1);
      final fresh = await fixture.capture().resolve(_capability);
      expect(fresh.binding.isSameRegistration(replacement), isTrue);
      expect(fresh.materialization, same(selection.materialization));
      expect(fixture.resolutions, 1);
    },
  );

  test(
    'explicit selection is eligible-only and unavailable choices stay failed',
    () async {
      final fixture = _Fixture();
      final captured = fixture.capture();
      for (final id in [
        fixture.primaryCallable.provider.id,
        ProviderId('test.unassociated'),
      ]) {
        await expectLater(
          captured.resolve(_capability, providerId: id),
          throwsA(isA<ProviderUnavailable>()),
        );
      }
      final missing = ProviderId('test.missing');
      await expectLater(
        captured.resolve(_capability, providerId: missing),
        throwsA(isA<ProviderUnavailable>()),
      );
      fixture.registerCallable(missing.value, fixture.anchor);
      await expectLater(
        captured.resolve(_capability, providerId: missing),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(fixture.selections, 3);
      final explicit = await captured.resolve(
        _capability,
        providerId: fixture.callable.provider.id,
      );
      expect(explicit.binding.isSameRegistration(fixture.callable), isTrue);
    },
  );

  test(
    'selection verifies association is present and exact, not same IDs',
    () async {
      final fixture = _Fixture();
      final foreign = _Fixture();
      for (final association in [null, fixture.primaryAnchor, foreign.anchor]) {
        final captured = fixture.capture(associationFor: (_) => association);
        await expectLater(
          captured.resolve(_capability),
          throwsA(isA<ProviderUnavailable>()),
        );
      }
      final selection = await fixture.capture().resolve(_capability);
      fixture.associations[fixture.callable] = foreign.anchor;
      expect(selection.validate, throwsA(isA<ProviderUnavailable>()));
    },
  );

  test(
    'selection rejects a resolver returning a different capability or provider',
    () async {
      final fixture = _Fixture();
      final captured = fixture.capture(
        resolve: (capability, {required associatedWith, providerId}) =>
            fixture.callable,
      );
      await expectLater(
        captured.resolve(_otherCapability),
        throwsA(isA<InvalidProviderRegistration>()),
      );
      await expectLater(
        captured.resolve(_capability, providerId: ProviderId('test.different')),
        throwsA(isA<InvalidProviderRegistration>()),
      );
    },
  );

  test(
    'both exact endpoints are validated without another provider selection',
    () async {
      final fixture = _Fixture();
      final captured = fixture.capture();
      final selection = await captured.resolve(_capability);
      for (final binding in [fixture.anchor, fixture.callable]) {
        final endpoint = binding.endpointAs<_Endpoint>();
        endpoint.available = false;
        expect(selection.validate, throwsA(isA<ProviderEndpointUnavailable>()));
        await expectLater(
          captured.resolve(_capability),
          throwsA(isA<ProviderEndpointUnavailable>()),
        );
        endpoint.available = true;
      }
      selection.validate();
      expect(fixture.resolutions, 1);
      expect(fixture.selections, 1);
    },
  );

  test(
    'production bootstrap never substitutes unowned same-plugin providers',
    () async {
      final fixture = _Fixture();
      final backends = ApplicationPluginBootstrap(
        fixture.registry,
        ExtensionRegistry(),
      );
      addTearDown(backends.close);
      await backends.start(installationRoot: '');
      expect(backends.backendForProvider(fixture.anchor), isNull);
      final captured = CapturedEnvironmentCapabilities(
        environmentRuntime: fixture.runtime,
        backends: backends,
        session: fixture.session,
      );
      await expectLater(
        captured.resolve(_capability),
        throwsA(isA<CapabilityUnavailable>()),
      );
      await expectLater(
        captured.resolve(_capability, providerId: fixture.callable.provider.id),
        throwsA(isA<ProviderUnavailable>()),
      );
      expect(fixture.additionalProvider.restored, [fixture.additional.id]);
      expect(fixture.resolutions, 1);
    },
  );

  test('eligibility alone cannot authorize an unowned callable', () async {
    final fixture = _Fixture();
    final selection = await fixture.capture().resolve(_capability);
    final backends = ApplicationPluginBootstrap(
      fixture.registry,
      ExtensionRegistry(),
    );
    addTearDown(backends.close);
    await backends.start(installationRoot: '');
    var invoked = false;
    await expectLater(
      invokeEnvironmentCapabilityWithRead<void>(
        selection: selection,
        backends: backends,
        serviceId: selection.binding.provider.serviceId,
        invoke: (_) async => invoked = true,
      ),
      throwsStateError,
    );
    expect(invoked, isFalse);
    expect(fixture.resolutions, 1);
    expect(fixture.selections, 1);
    selection.validate();
  });
}

final _stale = isA<ProviderUnavailable>().having(
  (error) => error.stale,
  'stale',
  isTrue,
);

final class _Fixture {
  _Fixture() {
    primary = Environment(
      id: EnvironmentId('primary'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: primaryProvider.providerId,
      providerState: const {'ready': true},
    );
    additional = Environment(
      id: EnvironmentId('additional'),
      taskId: task.id,
      role: EnvironmentRole.additional,
      providerId: additionalProvider.providerId,
      providerState: const {'ready': true},
    );
    store.publishRestoredProject(
      project: project,
      tasks: [task],
      environments: [primary, additional],
      sessions: [session, otherSession],
      authorities: [(session.id, additional.id), (otherSession.id, primary.id)],
      runRecords: const [],
    );
    primaryAnchor = registerEnvironment(primaryProvider);
    anchor = registerEnvironment(additionalProvider);
    primaryCallable = registerCallable('test.primary-callable', primaryAnchor);
    callable = registerCallable('test.additional-callable', anchor);
    registerCallable('test.unassociated', null);
    runtime = EnvironmentRuntime(
      store: store,
      registry: registry,
      providerForBinding: (binding) {
        resolutions++;
        return binding.endpointAs<_Endpoint>().environmentProvider!;
      },
      retainEnvironment: store.replaceEnvironment,
    );
  }

  final registry = CapabilityRegistry();
  final store = InMemoryProductStore();
  final project = Project(
    id: ProjectId('project'),
    sourceLocation: Uri.parse('file:///fixture'),
  );
  final task = Task(
    id: TaskId('task'),
    projectId: ProjectId('project'),
    title: 'Selection',
  );
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.missing-strategy'),
  );
  final otherSession = Session(
    id: SessionId('other-session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.missing-strategy'),
  );
  final primaryProvider = _Provider(ProviderId('test.primary-environment'));
  final additionalProvider = _Provider(
    ProviderId('test.additional-environment'),
  );
  final registrations = <ProviderBinding, CapabilityRegistration>{};
  final associations = <ProviderBinding, ProviderBinding>{};
  late final Environment primary;
  late final Environment additional;
  late final EnvironmentRuntime runtime;
  late final ProviderBinding primaryAnchor;
  late final ProviderBinding anchor;
  late final ProviderBinding primaryCallable;
  late final ProviderBinding callable;
  int resolutions = 0;
  int selections = 0;

  CapturedEnvironmentCapabilities capture({
    Session? session,
    AssociatedEnvironmentProviderResolver? resolve,
    ProviderBinding? Function(ProviderBinding)? associationFor,
  }) => CapturedEnvironmentCapabilities.withResolvers(
    environmentRuntime: runtime,
    session: session ?? this.session,
    resolveAssociatedProvider: resolve ?? select,
    associationFor: associationFor ?? this.associationFor,
  );

  ProviderBinding registerEnvironment(_Provider provider) => _register(
    provider.providerId,
    environmentProviderCapability,
    _Endpoint(environmentProviderServiceId, environmentProvider: provider),
  );

  ProviderBinding registerCallable(
    String id,
    ProviderBinding? associatedWith, {
    CapabilityKey? capability,
  }) {
    final binding = _register(
      ProviderId(id),
      capability ?? _capability,
      _Endpoint('test.callable'),
    );
    if (associatedWith != null) associations[binding] = associatedWith;
    return binding;
  }

  ProviderBinding _register(
    ProviderId id,
    CapabilityKey capability,
    _Endpoint endpoint,
  ) {
    final registration = registry.register(
      provider: ProviderDescriptor(
        id: id,
        capability: capability,
        pluginId: 'test.selection',
        displayName: id.value,
        serviceId: endpoint.serviceId,
      ),
      endpoint: endpoint,
    );
    addTearDown(registration.close);
    final binding = registry.resolve(capability, providerId: id);
    registrations[binding] = registration;
    return binding;
  }

  ProviderBinding? associationFor(ProviderBinding binding) {
    for (final entry in associations.entries) {
      if (entry.key.isSameRegistration(binding)) return entry.value;
    }
    return null;
  }

  ProviderBinding select(
    CapabilityKey capability, {
    required ProviderBinding associatedWith,
    ProviderId? providerId,
  }) {
    selections++;
    final eligible = <ProviderBinding>[];
    for (final provider in registry.providersFor(capability)) {
      final binding = registry.resolve(capability, providerId: provider.id);
      if (associationFor(binding)?.isSameRegistration(associatedWith) ??
          false) {
        eligible.add(binding);
      }
    }
    if (providerId == null) {
      if (eligible.isEmpty) throw CapabilityUnavailable(capability);
      return eligible.first;
    }
    for (final binding in eligible) {
      if (binding.provider.id == providerId) return binding;
    }
    throw ProviderUnavailable(
      capability: capability,
      providerId: providerId,
      availableProviderIds: eligible.map((binding) => binding.provider.id),
    );
  }
}

final class _Endpoint implements CapabilityEndpoint {
  _Endpoint(this.serviceId, {this.environmentProvider});

  @override
  final String serviceId;
  final _Provider? environmentProvider;
  bool available = true;

  @override
  bool get isAvailable => available;
}

final class _Provider implements EnvironmentProvider {
  _Provider(this.providerId);

  @override
  final ProviderId providerId;
  final restored = <EnvironmentId>[];
  Future<EnvironmentProviderResult>? restoration;
  Object? restoreFailure;

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restored.add(environment.id);
    if (restoreFailure case final failure?) throw failure;
    return restoration ??
        EnvironmentProviderResult(providerState: environment.providerState!);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
