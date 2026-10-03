import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/environment_text_files.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'capture is lazy and uses Session authority rather than Task primary',
    () {
      final fixture = _Fixture();
      final files = fixture.capture();

      expect(files.session, same(fixture.session));
      expect(files.environment, same(fixture.additional));
      expect(files.environmentId, fixture.additional.id);
      expect(files.environmentKey, fixture.additional.id.value);
      expect(
        fixture.store.primaryEnvironmentFor(fixture.task.id),
        same(fixture.primary),
      );
      expect(fixture.resolutions, 0);
      expect(fixture.provider.restored, isEmpty);
      expect(fixture.provider.reads, isEmpty);
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
    },
  );

  test('noncanonical and unknown Sessions fail synchronously', () {
    final fixture = _Fixture();
    for (final id in [fixture.session.id, SessionId('unknown-session')]) {
      expect(
        () => CapturedEnvironmentTextFiles(
          session: Session(
            id: id,
            taskId: fixture.session.taskId,
            strategyId: fixture.session.strategyId,
          ),
          environmentRuntime: fixture.runtime,
        ),
        throwsArgumentError,
      );
    }
    expect(fixture.resolutions, 0);
    expect(fixture.provider.restored, isEmpty);
  });

  test(
    'concurrent operations share lazy restoration and preserve arguments',
    () async {
      final fixture = _Fixture();
      final files = fixture.capture();
      final restoring = Completer<EnvironmentProviderResult>();
      fixture.provider.restoration = restoring.future;

      final read = files.read('lib/source.dart');
      final replacement = files.replace(
        'lib/source.dart',
        'replacement\r\ntext\n',
        'opaque:expected-revision',
      );
      expect(fixture.resolutions, 1);
      expect(fixture.provider.restored, [fixture.additional.id]);
      expect(fixture.provider.reads, isEmpty);
      expect(fixture.provider.replacements, isEmpty);
      restoring.complete(
        EnvironmentProviderResult(providerState: {'restored': true}),
      );

      expect(await read, same(fixture.provider.file));
      expect(await replacement, same(fixture.provider.replacement));
      expect(fixture.provider.reads, [
        (fixture.additional.id, 'lib/source.dart'),
      ]);
      expect(fixture.provider.replacements, [
        (
          fixture.additional.id,
          'lib/source.dart',
          'replacement\r\ntext\n',
          'opaque:expected-revision',
        ),
      ]);
      // Restore refreshes provider state without changing this captured identity.
      expect(
        fixture.store.environment(files.environmentId),
        isNot(same(files.environment)),
      );
      await files.read('another.txt');
      expect(fixture.resolutions, 1);
      expect(fixture.provider.restored, hasLength(1));
      expect(fixture.store.runsForSession(fixture.session.id), isEmpty);
    },
  );

  test(
    'navigation cannot retarget a capture before or during an await',
    () async {
      final fixture = _Fixture();
      var selected = fixture.session;
      final files = CapturedEnvironmentTextFiles(
        session: selected,
        environmentRuntime: fixture.runtime,
      );
      selected = fixture.otherSession;
      final otherFiles = CapturedEnvironmentTextFiles(
        session: selected,
        environmentRuntime: fixture.runtime,
      );
      final restoring = Completer<EnvironmentProviderResult>();
      fixture.provider.restoration = restoring.future;
      final pending = files.read('captured.txt');
      final otherPending = otherFiles.read('selected.txt');
      selected = fixture.session;
      restoring.complete(
        EnvironmentProviderResult(providerState: {'ready': true}),
      );
      await Future.wait([pending, otherPending]);
      await files.replace('captured.txt', 'original target', 'revision-1');

      expect(selected, same(fixture.session));
      expect(fixture.provider.reads, [
        (fixture.additional.id, 'captured.txt'),
        (fixture.primary.id, 'selected.txt'),
      ]);
      expect(fixture.provider.replacements.single.$1, fixture.additional.id);
      expect(otherFiles.environmentId, fixture.primary.id);
    },
  );

  test(
    'structured read and conditional replacement failures pass through',
    () async {
      final fixture = _Fixture();
      final files = fixture.capture();
      const missing = EnvironmentFailure(
        code: 'not_found',
        message: 'The file does not exist.',
        details: {'path': 'missing.txt', 'providerFact': 42},
      );
      const conflict = EnvironmentFailure(
        code: environmentRevisionConflictCode,
        message: 'The observed revision is stale.',
        details: {'path': 'source.txt', 'expectedRevision': 'old'},
      );
      fixture.provider.readFailure = missing;
      await expectLater(files.read('missing.txt'), throwsA(same(missing)));
      fixture.provider.replaceFailure = conflict;
      await expectLater(
        files.replace('source.txt', 'new text', 'old'),
        throwsA(same(conflict)),
      );
      expect(fixture.provider.replacements, [
        (fixture.additional.id, 'source.txt', 'new text', 'old'),
      ]);
      expect(fixture.provider.restored, hasLength(1));
    },
  );

  test('failed materialization is retained rather than retried', () async {
    final fixture = _Fixture();
    const failure = EnvironmentFailure(
      code: 'restore_failed',
      message: 'The retained provider state cannot be restored.',
      details: {'environment': 'additional'},
    );
    fixture.provider.restoreFailure = failure;
    final files = fixture.capture();
    await expectLater(files.read('source.txt'), throwsA(same(failure)));
    fixture.provider.restoreFailure = null;
    await expectLater(
      files.replace('source.txt', 'text', 'revision'),
      throwsA(same(failure)),
    );
    expect(fixture.provider.restored, hasLength(1));
    expect(fixture.provider.reads, isEmpty);
    expect(fixture.provider.replacements, isEmpty);
  });

  test(
    'missing provider is mapped and a capture never retries its lookup',
    () async {
      final fixture = _Fixture();
      await fixture.registration.close();
      final files = fixture.capture();
      final unavailable = isA<AuthorizedEnvironmentBindingUnavailable>().having(
        (error) => error.cause,
        'cause',
        isA<CapabilityUnavailable>(),
      );
      await expectLater(files.read('source.txt'), throwsA(unavailable));
      final replacement = _Provider(fixture.provider.providerId);
      fixture.register(replacement);
      await expectLater(
        files.replace('source.txt', 'text', 'revision'),
        throwsA(unavailable),
      );
      expect(replacement.restored, isEmpty);
      expect(replacement.replacements, isEmpty);
      await fixture.capture().read('source.txt');
      expect(replacement.restored, [fixture.additional.id]);
      expect(replacement.reads, [(fixture.additional.id, 'source.txt')]);
    },
  );

  test(
    'missing recorded provider never substitutes an available provider',
    () async {
      final fixture = _Fixture();
      await fixture.registration.close();
      final other = _Provider(ProviderId('test.another-provider'));
      fixture.register(other);
      final files = fixture.capture();

      await expectLater(
        files.read('source.txt'),
        throwsA(
          isA<AuthorizedEnvironmentBindingUnavailable>().having(
            (error) => error.cause,
            'cause',
            isA<ProviderUnavailable>().having(
              (error) => error.providerId,
              'providerId',
              fixture.provider.providerId,
            ),
          ),
        ),
      );
      expect(other.restored, isEmpty);
      expect(other.reads, isEmpty);
      expect(fixture.resolutions, 0);
    },
  );

  test(
    'unavailable endpoint is checked before read and replacement dispatch',
    () async {
      final fixture = _Fixture();
      final files = fixture.capture();
      await files.read('source.txt');
      fixture.endpoint.available = false;
      final unavailable = isA<AuthorizedEnvironmentBindingUnavailable>().having(
        (error) => error.cause,
        'cause',
        isA<ProviderEndpointUnavailable>(),
      );
      await expectLater(files.read('source.txt'), throwsA(unavailable));
      await expectLater(
        files.replace('source.txt', 'text', 'revision'),
        throwsA(unavailable),
      );
      expect(fixture.provider.reads, hasLength(1));
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.resolutions, 1);
    },
  );

  test(
    'provider dispatch errors retain their cause and failure category',
    () async {
      final fixture = _Fixture();
      final files = fixture.capture();
      for (final error in <Object>[
        CapabilityUnavailable(environmentProviderCapability),
        CapabilityVersionUnavailable(
          capabilityId: environmentProviderCapability.id,
          requestedMajorVersion: 1,
          availableMajorVersions: const [2],
        ),
        ProviderUnavailable(
          capability: environmentProviderCapability,
          providerId: fixture.provider.providerId,
          availableProviderIds: const [],
          stale: true,
        ),
        ProviderUnavailable(
          capability: environmentProviderCapability,
          providerId: fixture.provider.providerId,
          availableProviderIds: const [],
        ),
        ProviderEndpointUnavailable(fixture.provider.providerId),
        StateError('Unexpected provider failure'),
      ]) {
        final expected = switch (error) {
          ProviderUnavailable(stale: true) =>
            isA<AuthorizedEnvironmentBindingStale>().having(
              (failure) => failure.cause,
              'cause',
              same(error),
            ),
          CapabilityUnavailable() ||
          CapabilityVersionUnavailable() ||
          ProviderUnavailable() ||
          ProviderEndpointUnavailable() =>
            isA<AuthorizedEnvironmentBindingUnavailable>().having(
              (failure) => failure.cause,
              'cause',
              same(error),
            ),
          _ => same(error),
        };
        fixture.provider.readFailure = error;
        fixture.provider.replaceFailure = error;
        await expectLater(files.read('source.txt'), throwsA(expected));
        await expectLater(
          files.replace('source.txt', 'text', 'revision'),
          throwsA(expected),
        );
      }
      expect(fixture.resolutions, 1);
    },
  );

  test(
    'stale generation never migrates or replays through a replacement',
    () async {
      final fixture = _Fixture();
      final files = fixture.capture();
      await files.read('source.txt');
      await fixture.registration.close();
      final replacement = _Provider(fixture.provider.providerId);
      fixture.register(replacement);

      // A separate explicit capture may materialize the newly registered generation.
      await fixture.capture().read('fresh.txt');
      await expectLater(
        files.read('source.txt'),
        throwsA(isA<AuthorizedEnvironmentBindingStale>()),
      );
      await expectLater(
        files.replace('source.txt', 'must not be written', 'old'),
        throwsA(isA<AuthorizedEnvironmentBindingStale>()),
      );
      expect(fixture.provider.reads, [(fixture.additional.id, 'source.txt')]);
      expect(fixture.provider.replacements, isEmpty);
      expect(replacement.restored, [fixture.additional.id]);
      expect(replacement.reads, [(fixture.additional.id, 'fresh.txt')]);
      expect(replacement.replacements, isEmpty);
      expect(fixture.resolutions, 2);
    },
  );

  test(
    'retirement while materializing prevents dispatch and later retry',
    () async {
      final fixture = _Fixture();
      final restoring = Completer<EnvironmentProviderResult>();
      fixture.provider.restoration = restoring.future;
      final files = fixture.capture();
      final pending = expectLater(
        files.replace('source.txt', 'text', 'old'),
        throwsA(isA<AuthorizedEnvironmentBindingStale>()),
      );
      await fixture.registration.close();
      final replacement = _Provider(fixture.provider.providerId);
      fixture.register(replacement);
      restoring.complete(
        EnvironmentProviderResult(providerState: {'ready': true}),
      );
      await pending;
      await expectLater(
        files.read('source.txt'),
        throwsA(isA<AuthorizedEnvironmentBindingStale>()),
      );
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.provider.reads, isEmpty);
      expect(replacement.restored, isEmpty);
      expect(replacement.replacements, isEmpty);
    },
  );

  test(
    'an admitted replacement can succeed after retirement without replay',
    () async {
      final fixture = _Fixture();
      final files = fixture.capture();
      await files.read('source.txt');
      final replacing = Completer<EnvironmentTextFileReplacement>();
      fixture.provider.replacing = replacing.future;
      final pending = files.replace('source.txt', 'text', 'old');
      await fixture.provider.replacementStarted.future;
      await fixture.registration.close();
      replacing.complete(fixture.provider.replacement);

      expect(await pending, same(fixture.provider.replacement));
      expect(fixture.provider.replacements, hasLength(1));
      await expectLater(
        files.replace('source.txt', 'again', 'new'),
        throwsA(isA<AuthorizedEnvironmentBindingStale>()),
      );
      expect(fixture.provider.replacements, hasLength(1));
    },
  );
}

final class _Fixture {
  _Fixture() {
    primary = Environment(
      id: EnvironmentId('primary'),
      taskId: task.id,
      role: EnvironmentRole.primary,
      providerId: provider.providerId,
      providerState: const {'ready': true},
    );
    additional = Environment(
      id: EnvironmentId('additional'),
      taskId: task.id,
      role: EnvironmentRole.additional,
      providerId: provider.providerId,
      providerState: const {'ready': true},
    );
    store.publishRestoredProject(
      project: Project(
        id: task.projectId,
        sourceLocation: Uri.parse('file:///fixture'),
      ),
      tasks: [task],
      environments: [primary, additional],
      sessions: [session, otherSession],
      authorities: [(session.id, additional.id), (otherSession.id, primary.id)],
      runRecords: const [],
    );
    endpoint = _Endpoint(provider);
    registration = register(provider, endpoint: endpoint);
    runtime = EnvironmentRuntime(
      store: store,
      registry: registry,
      providerForBinding: (binding) {
        resolutions++;
        return binding.endpointAs<_Endpoint>().provider;
      },
      retainEnvironment: store.replaceEnvironment,
    );
  }

  final store = InMemoryProductStore();
  final registry = CapabilityRegistry();
  final provider = _Provider(ProviderId('test.text-files'));
  final task = Task(
    id: TaskId('task'),
    projectId: ProjectId('project'),
    title: 'Files',
  );
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.unavailable-strategy'),
  );
  final otherSession = Session(
    id: SessionId('other-session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.unavailable-strategy'),
  );
  late final Environment primary;
  late final Environment additional;
  late final EnvironmentRuntime runtime;
  late final _Endpoint endpoint;
  late final CapabilityRegistration registration;
  int resolutions = 0;

  CapturedEnvironmentTextFiles capture() => CapturedEnvironmentTextFiles(
    session: session,
    environmentRuntime: runtime,
  );

  CapabilityRegistration register(_Provider provider, {_Endpoint? endpoint}) {
    final registration = registry.register(
      provider: ProviderDescriptor(
        id: provider.providerId,
        capability: environmentProviderCapability,
        pluginId: 'test.text-files',
        displayName: 'Text files fixture',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: endpoint ?? _Endpoint(provider),
    );
    addTearDown(registration.close);
    return registration;
  }
}

final class _Endpoint implements CapabilityEndpoint {
  _Endpoint(this.provider);

  final _Provider provider;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String get serviceId => environmentProviderServiceId;
}

final class _Provider implements EnvironmentProvider {
  _Provider(this.providerId);

  @override
  final ProviderId providerId;
  final restored = <EnvironmentId>[];
  final reads = <(EnvironmentId, String)>[];
  final replacements = <(EnvironmentId, String, String, String)>[];
  final file = const EnvironmentTextFile(
    relativePath: 'provider/canonical.txt',
    text: 'original\r\ntext\n',
    sizeBytes: 15,
    revision: 'opaque:read-revision',
  );
  final replacement = const EnvironmentTextFileReplacement(
    revision: 'opaque:new-revision',
  );
  final replacementStarted = Completer<void>();
  Future<EnvironmentProviderResult>? restoration;
  Future<EnvironmentTextFileReplacement>? replacing;
  Object? restoreFailure;
  Object? readFailure;
  Object? replaceFailure;

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
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) async {
    reads.add((environmentId, relativePath));
    if (readFailure case final failure?) throw failure;
    return file;
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    replacements.add((
      environmentId,
      relativePath,
      replacementText,
      expectedRevision,
    ));
    if (!replacementStarted.isCompleted) replacementStarted.complete();
    if (replaceFailure case final failure?) throw failure;
    return replacing ?? replacement;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
