import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_desktop/development/agent/environment_tools.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Read File has one model-selectable relative path', () async {
    final _ToolFixture fixture = await _fixture();

    expect(
      fixture.executable.registration.definition.id,
      environmentFileReadToolId,
    );
    expect(fixture.executable.registration.modelDefinition.alias, 'read_file');
    expect(
      fixture.executable.validateAndNormalize(const <String, Object?>{
        'relativePath': 'app/lib/main.dart',
      }).snapshot,
      const <String, Object?>{'relativePath': 'app/lib/main.dart'},
    );
    for (final Map<String, Object?> invalid in <Map<String, Object?>>[
      const <String, Object?>{},
      const <String, Object?>{'relativePath': 42},
      const <String, Object?>{
        'relativePath': 'app/lib/main.dart',
        'environmentId': 'environment-1',
      },
    ]) {
      expect(
        () => fixture.executable.validateAndNormalize(invalid),
        throwsA(isA<ToolArgumentValidationException>()),
      );
    }
  });

  test(
    'Read File returns Environment content and structured host data',
    () async {
      final _ToolFixture fixture = await _fixture(text: 'final answer = 42;\n');
      final CanonicalToolArguments arguments = fixture.executable
          .validateAndNormalize(const <String, Object?>{
            'relativePath': 'app/lib/example.dart',
          });

      final EffectDescription effects = await fixture.executable.describe(
        arguments,
        fixture.context,
      );
      final ToolOutcome outcome = await _execute(
        fixture.executable,
        arguments,
        fixture.context,
      );

      expect(effects.effects, <ToolEffect>{ToolEffect.sourceRead});
      expect(
        effects.targets.single.uri.toString(),
        'adele-environment:/environment-1/app/lib/example.dart',
      );
      expect(outcome.disposition, ToolOutcomeDisposition.success);
      expect(
        outcome.modelContent,
        'File: app/lib/example.dart\nfinal answer = 42;\n',
      );
      expect(outcome.hostData, containsPair('environmentId', 'environment-1'));
      expect(
        outcome.hostData,
        containsPair('relativePath', 'app/lib/example.dart'),
      );
      expect(outcome.hostData, containsPair('sizeBytes', 19));
      expect(outcome.hostData, containsPair('text', 'final answer = 42;\n'));
      expect(fixture.provider.readCalls, 1);
    },
  );

  test('Read File preserves Environment domain failure details', () async {
    final _ToolFixture fixture = await _fixture(
      readError: const EnvironmentFailure(
        code: 'not_found',
        message: 'Environment file was not found.',
        details: <String, Object?>{'path': 'missing.dart'},
      ),
    );
    final CanonicalToolArguments arguments = fixture.executable
        .validateAndNormalize(const <String, Object?>{
          'relativePath': 'missing.dart',
        });

    final ToolOutcome outcome = await _execute(
      fixture.executable,
      arguments,
      fixture.context,
    );

    expect(outcome.disposition, ToolOutcomeDisposition.failure);
    expect(outcome.failureKind, ToolFailureKind.domain);
    expect(outcome.hostData['code'], 'not_found');
    expect(outcome.hostData['details'], <String, Object?>{
      'path': 'missing.dart',
    });
  });

  test(
    'Read File maps unavailable endpoint and transport separately',
    () async {
      final _ToolFixture unavailable = await _fixture();
      unavailable.endpoint.available = false;
      final CanonicalToolArguments arguments = unavailable.executable
          .validateAndNormalize(const <String, Object?>{
            'relativePath': 'source.dart',
          });

      expect(
        unavailable.executable.validateBinding,
        throwsA(isA<ToolBindingUnavailableException>()),
      );
      final ToolOutcome unavailableOutcome = await _execute(
        unavailable.executable,
        arguments,
        unavailable.context,
      );
      expect(unavailableOutcome.failureKind, ToolFailureKind.infrastructure);
      expect(
        unavailableOutcome.effectCertainty,
        EffectCertainty.knownNotOccurred,
      );
      expect(unavailable.provider.readCalls, 0);

      final _ToolFixture transport = await _fixture(
        readError: StateError('transport closed'),
      );
      final ToolOutcome transportOutcome = await _execute(
        transport.executable,
        arguments,
        transport.context,
      );
      expect(transportOutcome.failureKind, ToolFailureKind.infrastructure);
      expect(transportOutcome.effectCertainty, EffectCertainty.uncertain);
    },
  );

  test(
    'Read File rejects a ToolExecutionContext from another Session',
    () async {
      final _ToolFixture fixture = await _fixture();
      final CanonicalToolArguments arguments = fixture.executable
          .validateAndNormalize(const <String, Object?>{
            'relativePath': 'source.dart',
          });

      await expectLater(
        fixture.executable.describe(
          arguments,
          ToolExecutionContext(
            runId: RunId('wrong-run'),
            sessionId: SessionId('wrong-session'),
          ),
        ),
        throwsA(isA<Exception>()),
      );
      final ToolOutcome outcome = await _execute(
        fixture.executable,
        arguments,
        ToolExecutionContext(
          runId: RunId('wrong-run'),
          sessionId: SessionId('wrong-session'),
        ),
      );
      expect(outcome.failureKind, ToolFailureKind.infrastructure);
      expect(outcome.effectCertainty, EffectCertainty.knownNotOccurred);
      expect(fixture.provider.readCalls, 0);
    },
  );

  test(
    'old Read File stays stale while fresh tool restores generation B',
    () async {
      final _ToolFixture generationA = await _fixture(text: 'generation A');
      final EnvironmentReadFileToolExecutable oldTool = generationA.executable;
      final CanonicalToolArguments arguments = oldTool.validateAndNormalize(
        const <String, Object?>{'relativePath': 'source.dart'},
      );
      await generationA.registration.close();
      final _EnvironmentProvider generationB = _EnvironmentProvider(
        generationA.provider.providerId,
        text: 'generation B',
      );
      final _EnvironmentEndpoint endpointB = _EnvironmentEndpoint(generationB);
      final CapabilityRegistration registrationB = generationA.registry
          .register(
            provider: _descriptor(generationB.providerId),
            endpoint: endpointB,
          );
      addTearDown(registrationB.close);

      expect(
        oldTool.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      final ToolOutcome staleOutcome = await _execute(
        oldTool,
        arguments,
        generationA.context,
      );
      expect(staleOutcome.failureKind, ToolFailureKind.staleBinding);
      expect(generationA.provider.readCalls, 0);
      expect(generationB.readCalls, 0);

      final ToolCatalog freshCatalog =
          await buildEnvironmentToolCatalogForSession(
            sessionId: generationA.sessionId,
            environmentRuntime: generationA.runtime,
          );
      final EnvironmentReadFileToolExecutable freshTool =
          freshCatalog.materialize().byAlias('read_file')!.executable
              as EnvironmentReadFileToolExecutable;
      final ToolOutcome freshOutcome = await _execute(
        freshTool,
        arguments,
        generationA.context,
      );

      expect(generationB.restoreCalls, 1);
      expect(freshOutcome.disposition, ToolOutcomeDisposition.success);
      expect(freshOutcome.modelContent, contains('generation B'));
      expect(generationB.readCalls, 1);
      expect(
        oldTool.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
    },
  );
}

Future<_ToolFixture> _fixture({
  String text = 'source',
  Object? readError,
}) async {
  final ProviderId providerId = ProviderId(
    'dev.adele.environment.read-tool-fixture',
  );
  final _EnvironmentProvider provider = _EnvironmentProvider(
    providerId,
    text: text,
    readError: readError,
  );
  final _EnvironmentEndpoint endpoint = _EnvironmentEndpoint(provider);
  final CapabilityRegistry registry = CapabilityRegistry();
  final CapabilityRegistration registration = registry.register(
    provider: _descriptor(providerId),
    endpoint: endpoint,
  );
  addTearDown(registration.close);
  final InMemoryProductStore store = InMemoryProductStore();
  final ProductLifecycleCoordinator coordinator = ProductLifecycleCoordinator(
    store: store,
    registry: registry,
    ids: const _Ids(),
    providerForBinding: (ProviderBinding binding) =>
        binding.endpointAs<_EnvironmentEndpoint>().provider,
  );
  final Project project = coordinator.createProject(
    Uri.parse('file:///tmp/read-tool-source'),
  );
  final TaskCreationResult created = await coordinator.createTask(
    projectId: project.id,
    title: 'Read an Environment file',
    providerId: providerId,
  );
  final SessionId sessionId = SessionId('session-1');
  store.associateSession(sessionId: sessionId, taskId: created.task.id);
  final ToolCatalog catalog = await buildEnvironmentToolCatalogForSession(
    sessionId: sessionId,
    environmentRuntime: coordinator.environmentRuntime,
  );
  final EnvironmentReadFileToolExecutable executable =
      catalog.materialize().byAlias('read_file')!.executable
          as EnvironmentReadFileToolExecutable;
  return _ToolFixture(
    sessionId: sessionId,
    runtime: coordinator.environmentRuntime,
    registry: registry,
    registration: registration,
    endpoint: endpoint,
    provider: provider,
    executable: executable,
  );
}

Future<ToolOutcome> _execute(
  EnvironmentReadFileToolExecutable executable,
  CanonicalToolArguments arguments,
  ToolExecutionContext context,
) async =>
    (await executable.execute(arguments, context).single
            as ToolExecutionTerminal)
        .outcome;

ProviderDescriptor _descriptor(ProviderId providerId) => ProviderDescriptor(
  id: providerId,
  capability: environmentProviderCapability,
  pluginId: 'dev.adele.plugin.read-tool-fixture',
  displayName: 'Read Tool Fixture',
  serviceId: environmentProviderServiceId,
);

final class _ToolFixture {
  const _ToolFixture({
    required this.sessionId,
    required this.runtime,
    required this.registry,
    required this.registration,
    required this.endpoint,
    required this.provider,
    required this.executable,
  });

  final SessionId sessionId;
  final EnvironmentRuntime runtime;
  final CapabilityRegistry registry;
  final CapabilityRegistration registration;
  final _EnvironmentEndpoint endpoint;
  final _EnvironmentProvider provider;
  final EnvironmentReadFileToolExecutable executable;

  ToolExecutionContext get context =>
      ToolExecutionContext(runId: RunId('run-1'), sessionId: sessionId);
}

final class _EnvironmentEndpoint implements CapabilityEndpoint {
  _EnvironmentEndpoint(this.provider);

  final _EnvironmentProvider provider;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String get serviceId => environmentProviderServiceId;
}

final class _EnvironmentProvider implements EnvironmentProvider {
  _EnvironmentProvider(this.providerId, {required this.text, this.readError});

  @override
  final ProviderId providerId;
  final String text;
  final Object? readError;
  int readCalls = 0;
  int restoreCalls = 0;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async => EnvironmentProviderResult(
    providerState: <String, Object?>{'environmentId': environment.id.value},
  );

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restoreCalls++;
    return EnvironmentProviderResult(providerState: environment.providerState!);
  }

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) async {
    readCalls++;
    if (readError case final Object error) throw error;
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: text.length,
    );
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();
}

final class _Ids implements ProductIdSource {
  const _Ids();

  @override
  EnvironmentId nextEnvironmentId() => EnvironmentId('environment-1');

  @override
  ProjectId nextProjectId() => ProjectId('project-1');

  @override
  TaskId nextTaskId() => TaskId('task-1');
}
