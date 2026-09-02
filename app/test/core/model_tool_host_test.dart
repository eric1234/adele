import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'inactive plugin is absent and active plugin uses Session authority',
    () async {
      final _Fixture fixture = await _fixture();
      final ExtensionRegistry extensions = ExtensionRegistry();

      expect(
        (await buildModelToolCatalogForSession(
          sessionId: fixture.sessionId,
          environmentRuntime: fixture.runtime,
          extensions: extensions,
        )).materialize().tools,
        isEmpty,
      );

      final ExtensionRegistration activation = const FilesystemToolsPlugin()
          .activate(extensions);
      final ToolCatalog catalog = await buildModelToolCatalogForSession(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
        extensions: extensions,
      );
      final MaterializedTool tool = catalog.materialize().byAlias('read_file')!;
      final Object? properties =
          tool.modelDefinition.argumentsSchema['properties'];
      expect(properties, isA<Map<String, Object?>>());
      expect((properties! as Map<String, Object?>).keys, <String>[
        'relativePath',
      ]);
      final CanonicalToolArguments arguments = tool.executable
          .validateAndNormalize(const <String, Object?>{
            'relativePath': 'source.dart',
          });
      final ToolOutcome outcome =
          (await tool.executable
                      .execute(
                        arguments,
                        ToolExecutionContext(
                          runId: RunId('run-1'),
                          sessionId: fixture.sessionId,
                        ),
                      )
                      .single
                  as ToolExecutionTerminal)
              .outcome;

      expect(outcome.modelContent, contains('authorized source'));
      expect(fixture.provider.environmentIds, <EnvironmentId>[
        fixture.environmentId,
      ]);

      await activation.close();
      expect(
        tool.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        (await buildModelToolCatalogForSession(
          sessionId: fixture.sessionId,
          environmentRuntime: fixture.runtime,
          extensions: extensions,
        )).materialize().tools,
        isEmpty,
      );
    },
  );
}

Future<_Fixture> _fixture() async {
  final ProviderId providerId = ProviderId('dev.adele.environment.host-test');
  final _Provider provider = _Provider(providerId);
  final CapabilityRegistry registry = CapabilityRegistry();
  final CapabilityRegistration registration = registry.register(
    provider: ProviderDescriptor(
      id: providerId,
      capability: environmentProviderCapability,
      pluginId: 'dev.adele.plugin.host-test',
      displayName: 'Host Test',
      serviceId: environmentProviderServiceId,
    ),
    endpoint: _Endpoint(provider),
  );
  addTearDown(registration.close);
  final InMemoryProductStore store = InMemoryProductStore();
  final ProductLifecycleCoordinator lifecycle = ProductLifecycleCoordinator(
    store: store,
    registry: registry,
    ids: const _Ids(),
    providerForBinding: (binding) => binding.endpointAs<_Endpoint>().provider,
  );
  final Project project = lifecycle.createProject(Uri.parse('file:///source'));
  final TaskCreationResult created = await lifecycle.createTask(
    projectId: project.id,
    title: 'Host tools',
    providerId: providerId,
  );
  final SessionId sessionId = SessionId('session-1');
  store.associateSession(sessionId: sessionId, taskId: created.task.id);
  return _Fixture(
    sessionId,
    created.environment.id,
    lifecycle.environmentRuntime,
    provider,
  );
}

final class _Fixture {
  const _Fixture(
    this.sessionId,
    this.environmentId,
    this.runtime,
    this.provider,
  );

  final SessionId sessionId;
  final EnvironmentId environmentId;
  final EnvironmentRuntime runtime;
  final _Provider provider;
}

final class _Endpoint implements CapabilityEndpoint {
  const _Endpoint(this.provider);

  final _Provider provider;

  @override
  bool get isAvailable => true;

  @override
  String get serviceId => environmentProviderServiceId;
}

final class _Provider implements EnvironmentProvider {
  _Provider(this.providerId);

  @override
  final ProviderId providerId;
  final List<EnvironmentId> environmentIds = <EnvironmentId>[];

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async => EnvironmentProviderResult(
    providerState: <String, Object?>{'ready': true},
  );

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async =>
      EnvironmentProviderResult(providerState: environment.providerState!);

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) async {
    environmentIds.add(environmentId);
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: 'authorized source',
      sizeBytes: 17,
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
