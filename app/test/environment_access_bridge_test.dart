import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/frontend/environment_access_bridge.dart';
import 'package:adele_desktop/frontend/environment_text_files.dart';
import 'package:adele_desktop/frontend/structured_bridge_data.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_ui/environment_access_bridge.dart' as public_bridge;
import 'package:dart_eval/dart_eval.dart';
import 'package:flutter_test/flutter_test.dart';

const _library = 'package:environment_access_probe/main.dart';
const _unavailable = {
  'ok': false,
  'failure': {
    'code': 'binding_unavailable',
    'message': 'Environment file access is unavailable.',
    'details': <String, Object?>{},
  },
};
const _unacknowledged = {
  'ok': false,
  'failure': {
    'code': 'operation_unacknowledged',
    'message': 'The Environment operation was not acknowledged.',
    'details': <String, Object?>{},
  },
};

void main() {
  late Program program;
  setUpAll(() async {
    program =
        (Compiler()
              ..addPlugin(const EnvironmentAccessDeclarations())
              ..entrypoints.add(_library))
            .compile({
              'adele_ui': {
                'environment_access_bridge.dart': await File(
                  '../packages/ui/lib/environment_access_bridge.dart',
                ).readAsString(),
              },
              'environment_access_probe': {
                'main.dart': r'''
import 'package:adele_ui/environment_access_bridge.dart';
Future<Map<String, dynamic>> read() async {
  return await readEnvironmentTextFile('relative/../requested.txt');
}
Future<Map<String, dynamic>> replace() async {
  return await replaceEnvironmentTextFile('requested.txt', 'new\r\ntext\n', 'opaque:expected');
}
''',
              },
            });
  });

  Runtime runtime(EnvironmentAccessBridge bridge) =>
      Runtime(ByteData.sublistView(program.write()))..addPlugin(bridge);

  Future<Map<String, Object?>> invoke(
    Runtime runtime,
    String entrypoint,
  ) async =>
      copyStructuredBridgeData(await runtime.executeLib(_library, entrypoint))
          as Map<String, Object?>;

  test(
    'stubs and declarations grant no native access; bridges bind once',
    () async {
      expect(
        () => public_bridge.readEnvironmentTextFile('requested.txt'),
        throwsUnsupportedError,
      );
      expect(
        () => public_bridge.replaceEnvironmentTextFile('requested.txt', '', ''),
        throwsUnsupportedError,
      );
      final bridge = EnvironmentAccessBridge(isActive: () => true);
      final eval = runtime(bridge);
      await invoke(eval, 'read');
      expect(
        () => const EnvironmentAccessDeclarations().configureForRuntime(eval),
        throwsUnsupportedError,
      );
      expect(() => bridge.configureForRuntime(eval), throwsStateError);
    },
  );

  test(
    'EVC forwards complete DTOs and unchanged replacement arguments',
    () async {
      final fixture = _Fixture();
      fixture.provider.file = EnvironmentTextFile(
        relativePath: 'normalized.txt',
        text: 'whole\r\n' * 20000,
        sizeBytes: 140000,
        revision: 'opaque:read',
      );
      final eval = runtime(
        EnvironmentAccessBridge(isActive: () => true, files: fixture.capture()),
      );
      expect(fixture.provider.restores, 0);
      expect(await invoke(eval, 'read'), {
        'ok': true,
        'path': 'normalized.txt',
        'text': fixture.provider.file.text,
        'sizeBytes': 140000,
        'revision': 'opaque:read',
      });
      expect(await invoke(eval, 'replace'), {
        'ok': true,
        'revision': 'opaque:replacement',
      });
      expect(fixture.provider.reads, [
        (fixture.environment.id, 'relative/../requested.txt'),
      ]);
      expect(fixture.provider.replacements, [
        (
          fixture.environment.id,
          'requested.txt',
          'new\r\ntext\n',
          'opaque:expected',
        ),
      ]);
      expect(fixture.provider.restores, 1);
    },
  );

  test('denied views and operations never materialize or dispatch', () async {
    final fixture = _Fixture();
    for (final bridge in [
      EnvironmentAccessBridge(isActive: () => true),
      EnvironmentAccessBridge(isActive: () => false, files: fixture.capture()),
      EnvironmentAccessBridge(
        isActive: () => throw StateError('liveness failed'),
        files: fixture.capture(),
      ),
      EnvironmentAccessBridge(isActive: () => true, files: fixture.capture())
        ..invalidate(),
    ]) {
      final eval = runtime(bridge);
      expect(await invoke(eval, 'read'), _unavailable);
      expect(await invoke(eval, 'replace'), _unavailable);
    }
    expect(fixture.provider.restores, 0);
    expect(fixture.provider.reads, isEmpty);
    expect(fixture.provider.replacements, isEmpty);
  });

  test('observed admission loss cannot revive the same bridge', () async {
    final fixture = _Fixture();
    var active = false;
    final files = fixture.capture();
    final eval = runtime(
      EnvironmentAccessBridge(isActive: () => active, files: files),
    );
    expect(await invoke(eval, 'read'), _unavailable);
    active = true;
    expect(await invoke(eval, 'replace'), _unavailable);
    expect(fixture.provider.restores, 0);
    final fresh = runtime(
      EnvironmentAccessBridge(isActive: () => active, files: files),
    );
    expect((await invoke(fresh, 'read'))['ok'], true);
    expect(fixture.provider.restores, 1);
  });

  test(
    'EVC preserves structured failures and contains unknown failures',
    () async {
      final fixture = _Fixture();
      final eval = runtime(
        EnvironmentAccessBridge(isActive: () => true, files: fixture.capture()),
      );
      const failure = EnvironmentFailure(
        code: 'revision_conflict',
        message: 'The observed revision is stale.',
        details: {
          'path': 'normalized.txt',
          'facts': [
            42,
            true,
            null,
            {'revision': 'opaque:current'},
          ],
        },
      );
      for (final (error, expected) in <(Object, Map<String, Object?>)>[
        (
          failure,
          {
            'ok': false,
            'failure': {
              'code': failure.code,
              'message': failure.message,
              'details': failure.details,
            },
          },
        ),
        (
          const AuthorizedEnvironmentBindingStale('Exact binding retired.'),
          {
            'ok': false,
            'failure': {
              'code': 'binding_stale',
              'message': 'Exact binding retired.',
              'details': <String, Object?>{},
            },
          },
        ),
        (
          const AuthorizedEnvironmentBindingUnavailable(
            'Endpoint unavailable.',
          ),
          {
            'ok': false,
            'failure': {
              'code': 'binding_unavailable',
              'message': 'Endpoint unavailable.',
              'details': <String, Object?>{},
            },
          },
        ),
        (StateError('private native diagnostics'), _unacknowledged),
        (
          EnvironmentFailure(
            code: 'invalid_details',
            message: 'Cannot cross the bridge.',
            details: {'native': Object()},
          ),
          _unacknowledged,
        ),
      ]) {
        fixture.provider.failure = error;
        expect(await invoke(eval, 'read'), expected);
        expect(await invoke(eval, 'replace'), expected);
      }
      expect(fixture.provider.reads, hasLength(5));
      expect(fixture.provider.replacements, hasLength(5));
      expect(fixture.provider.restores, 1);
    },
  );

  test('an acquired binding never migrates to the next provider', () async {
    final fixture = _Fixture();
    final eval = runtime(
      EnvironmentAccessBridge(isActive: () => true, files: fixture.capture()),
    );
    await invoke(eval, 'read');
    await fixture.registration.close();
    final replacement = _Provider();
    fixture.register(replacement);
    final fresh = runtime(
      EnvironmentAccessBridge(isActive: () => true, files: fixture.capture()),
    );
    expect((await invoke(fresh, 'read'))['ok'], true);
    for (final operation in ['read', 'replace']) {
      final result = await invoke(eval, operation);
      expect(result['ok'], false);
      expect((result['failure'] as Map)['code'], 'binding_stale');
    }
    expect(fixture.provider.reads, hasLength(1));
    expect(fixture.provider.replacements, isEmpty);
    expect(replacement.reads, hasLength(1));
    expect(replacement.replacements, isEmpty);
  });

  test('failed capture stays memoized; a fresh capture may recover', () async {
    final fixture = _Fixture();
    final files = fixture.capture();
    fixture.provider.restoreFailure = StateError('restore failed');
    final first = runtime(
      EnvironmentAccessBridge(isActive: () => true, files: files),
    );
    expect(await invoke(first, 'read'), _unacknowledged);
    fixture.provider.restoreFailure = null;
    final sameCapture = runtime(
      EnvironmentAccessBridge(isActive: () => true, files: files),
    );
    expect(await invoke(sameCapture, 'replace'), _unacknowledged);
    expect(fixture.provider.restores, 1);
    expect(fixture.provider.reads, isEmpty);
    expect(fixture.provider.replacements, isEmpty);
    final fresh = runtime(
      EnvironmentAccessBridge(isActive: () => true, files: fixture.capture()),
    );
    expect((await invoke(fresh, 'read'))['ok'], true);
    expect(fixture.provider.restores, 2);
    expect(fixture.provider.reads, hasLength(1));
  });

  for (final operation in ['read', 'replace']) {
    test('admitted $operation acknowledgement survives revocation', () async {
      final fixture = _Fixture();
      final gate = Completer<void>();
      fixture.provider.gate = gate.future;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      var active = true;
      final bridge = EnvironmentAccessBridge(
        isActive: () => active,
        files: fixture.capture(),
      );
      final eval = runtime(bridge);
      final pending = invoke(eval, operation);
      await fixture.provider.started.future;
      active = false;
      bridge.invalidate();
      gate.complete();
      final result = await pending;
      expect(result['ok'], true);
      expect(
        result['revision'],
        operation == 'read' ? 'opaque:read' : 'opaque:replacement',
      );
      expect(await invoke(eval, operation), _unavailable);
      expect(
        fixture.provider.reads.length + fixture.provider.replacements.length,
        1,
      );
    });
  }

  test('native errors settle as maps outside the eval error zone', () async {
    final fixture = _Fixture();
    fixture.provider.failure = StateError('native failure');
    final bridge = runZoned(
      () => EnvironmentAccessBridge(
        isActive: () => true,
        files: fixture.capture(),
      ),
      zoneValues: {#environmentAccessZone: 'native'},
    );
    final completion = Completer<Map<String, Object?>>();
    final errors = <Object>[];
    runZonedGuarded(
      () async => completion.complete(await invoke(runtime(bridge), 'replace')),
      (error, _) {
        errors.add(error);
        if (!completion.isCompleted) completion.completeError(error);
      },
      zoneValues: {#environmentAccessZone: 'eval'},
    );
    expect(await completion.future, _unacknowledged);
    expect(fixture.provider.operationZone, 'native');
    expect(errors, isEmpty);
    expect(fixture.provider.replacements, hasLength(1));
  });
}

final class _Fixture {
  _Fixture() {
    store.publishRestoredProject(
      project: Project(
        id: task.projectId,
        sourceLocation: Uri.parse('file:///fixture'),
      ),
      tasks: [task],
      environments: [environment],
      sessions: [session],
      authorities: [(session.id, environment.id)],
      runRecords: const [],
    );
    registration = register(provider);
    environmentRuntime = EnvironmentRuntime(
      store: store,
      registry: registry,
      providerForBinding: (binding) => binding.endpointAs<_Endpoint>().provider,
      retainEnvironment: store.replaceEnvironment,
    );
  }

  final store = InMemoryProductStore();
  final registry = CapabilityRegistry();
  final provider = _Provider();
  final task = Task(
    id: TaskId('task'),
    projectId: ProjectId('project'),
    title: 'Files',
  );
  final environment = Environment(
    id: EnvironmentId('environment'),
    taskId: TaskId('task'),
    role: EnvironmentRole.primary,
    providerId: ProviderId('test.environment-access'),
    providerState: const {'ready': true},
  );
  final session = Session(
    id: SessionId('session'),
    taskId: TaskId('task'),
    strategyId: OrchestrationStrategyId('test.unavailable'),
  );
  late final CapabilityRegistration registration;
  late final EnvironmentRuntime environmentRuntime;

  CapturedEnvironmentTextFiles capture() => CapturedEnvironmentTextFiles(
    session: session,
    environmentRuntime: environmentRuntime,
  );

  CapabilityRegistration register(_Provider provider) {
    final registration = registry.register(
      provider: ProviderDescriptor(
        id: provider.providerId,
        capability: environmentProviderCapability,
        pluginId: 'test.environment-access',
        displayName: 'Environment access fixture',
        serviceId: environmentProviderServiceId,
      ),
      endpoint: _Endpoint(provider),
    );
    addTearDown(registration.close);
    return registration;
  }
}

final class _Endpoint implements CapabilityEndpoint {
  _Endpoint(this.provider);

  final _Provider provider;

  @override
  bool get isAvailable => true;

  @override
  String get serviceId => environmentProviderServiceId;
}

final class _Provider implements EnvironmentProvider {
  @override
  final providerId = ProviderId('test.environment-access');
  int restores = 0;
  final reads = <(EnvironmentId, String)>[];
  final replacements = <(EnvironmentId, String, String, String)>[];
  final started = Completer<void>();
  Future<void>? gate;
  Object? failure;
  Object? restoreFailure;
  Object? operationZone;
  EnvironmentTextFile file = const EnvironmentTextFile(
    relativePath: 'normalized.txt',
    text: 'original\r\n',
    sizeBytes: 10,
    revision: 'opaque:read',
  );

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restores++;
    if (restoreFailure case final error?) throw error;
    return EnvironmentProviderResult(providerState: environment.providerState!);
  }

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) async {
    operationZone = Zone.current[#environmentAccessZone];
    reads.add((environmentId, relativePath));
    if (!started.isCompleted) started.complete();
    await gate;
    if (failure case final error?) throw error;
    return file;
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    operationZone = Zone.current[#environmentAccessZone];
    replacements.add((
      environmentId,
      relativePath,
      replacementText,
      expectedRevision,
    ));
    if (!started.isCompleted) started.complete();
    await gate;
    if (failure case final error?) throw error;
    return const EnvironmentTextFileReplacement(revision: 'opaque:replacement');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
