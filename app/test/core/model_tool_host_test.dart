import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

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
      final MaterializedToolSet tools = catalog.materialize();
      final MaterializedTool tool = tools.byAlias('read_file')!;
      final MaterializedTool applyPatch = tools.byAlias('apply_patch')!;
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
        applyPatch.executable.validateBinding,
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

  test('Filesystem and Search plugins activate independently', () async {
    final _Fixture fixture = await _fixture();
    final ExtensionRegistry extensions = ExtensionRegistry();

    Future<Set<String>> aliases() async =>
        (await buildModelToolCatalogForSession(
              sessionId: fixture.sessionId,
              environmentRuntime: fixture.runtime,
              extensions: extensions,
            ))
            .materialize()
            .tools
            .map((tool) => tool.modelDefinition.alias)
            .toSet();

    expect(await aliases(), isEmpty);
    final ExtensionRegistration filesystem = const FilesystemToolsPlugin()
        .activate(extensions);
    expect(await aliases(), <String>{'read_file', 'apply_patch'});
    await filesystem.close();

    final ExtensionRegistration search = const SearchToolsPlugin().activate(
      extensions,
    );
    expect(await aliases(), <String>{'search'});
    final ExtensionRegistration bothFilesystem = const FilesystemToolsPlugin()
        .activate(extensions);
    expect(await aliases(), <String>{'search', 'read_file', 'apply_patch'});
    await search.close();
    await bothFilesystem.close();
  });

  test('authorized facets share Session Environment and generation', () async {
    final _Fixture fixture = await _fixture();
    final SessionModelToolHostContext context = SessionModelToolHostContext(
      sessionId: fixture.sessionId,
      environmentRuntime: fixture.runtime,
    );
    final AuthorizedEnvironmentFileSystem authority = await context
        .requireHostService<AuthorizedEnvironmentFileSystem>();
    final AuthorizedEnvironmentFileReadFacet read = await context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet mutation = await context
        .requireHostService<AuthorizedEnvironmentFileMutationFacet>();

    expect(
      await context.requireHostService<AuthorizedEnvironmentFileSystem>(),
      same(authority),
    );
    expect(
      await context.requireHostService<AuthorizedEnvironmentFileReadFacet>(),
      same(read),
    );
    expect(
      await context
          .requireHostService<AuthorizedEnvironmentFileMutationFacet>(),
      same(mutation),
    );
    expect(
      <SessionId>{authority.sessionId, read.sessionId, mutation.sessionId},
      <SessionId>{fixture.sessionId},
    );
    expect(
      <EnvironmentId>{
        authority.environmentId,
        read.environmentId,
        mutation.environmentId,
      },
      <EnvironmentId>{fixture.environmentId},
    );

    final EnvironmentDirectoryListing listing = await read.readDirectory(
      'nested',
    );
    final EnvironmentTextFileReplacement replacement = await mutation
        .replaceExistingTextFile('source.dart', 'replacement', 'R1');
    expect(listing.relativePath, 'nested');
    expect(replacement.revision, 'replacement-revision');
    expect(fixture.provider.directoryEnvironmentIds, <EnvironmentId>[
      fixture.environmentId,
    ]);
    expect(fixture.provider.replacements.single, (
      environmentId: fixture.environmentId,
      relativePath: 'source.dart',
      replacementText: 'replacement',
      expectedRevision: 'R1',
    ));

    await fixture.registration.close();
    await expectLater(
      read.readFile('source.dart'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      mutation.replaceExistingTextFile('source.dart', 'other', 'R2'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
  });

  test('provider unavailability affects both facets consistently', () async {
    final _Fixture fixture = await _fixture();
    final SessionModelToolHostContext context = SessionModelToolHostContext(
      sessionId: fixture.sessionId,
      environmentRuntime: fixture.runtime,
    );
    final AuthorizedEnvironmentFileReadFacet read = await context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet mutation = await context
        .requireHostService<AuthorizedEnvironmentFileMutationFacet>();
    fixture.endpoint.available = false;

    await expectLater(
      read.readDirectory('nested'),
      throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
    );
    await expectLater(
      mutation.replaceExistingTextFile('source.dart', 'other', 'R1'),
      throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
    );
  });

  test('fresh host context receives fresh provider facet bindings', () async {
    final _Fixture fixture = await _fixture();
    final SessionModelToolHostContext oldContext = SessionModelToolHostContext(
      sessionId: fixture.sessionId,
      environmentRuntime: fixture.runtime,
    );
    final AuthorizedEnvironmentFileReadFacet oldRead = await oldContext
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet oldMutation = await oldContext
        .requireHostService<AuthorizedEnvironmentFileMutationFacet>();
    await fixture.registration.close();

    final _Provider replacementProvider = _Provider(
      fixture.providerId,
      sourceText: 'fresh generation source',
    );
    final _Endpoint replacementEndpoint = _Endpoint(replacementProvider);
    final CapabilityRegistration replacementRegistration = fixture.registry
        .register(
          provider: ProviderDescriptor(
            id: fixture.providerId,
            capability: environmentProviderCapability,
            pluginId: 'dev.adele.plugin.host-test',
            displayName: 'Host Test Replacement',
            serviceId: environmentProviderServiceId,
          ),
          endpoint: replacementEndpoint,
        );
    addTearDown(replacementRegistration.close);
    final SessionModelToolHostContext freshContext =
        SessionModelToolHostContext(
          sessionId: fixture.sessionId,
          environmentRuntime: fixture.runtime,
        );
    final AuthorizedEnvironmentFileReadFacet freshRead = await freshContext
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet freshMutation =
        await freshContext
            .requireHostService<AuthorizedEnvironmentFileMutationFacet>();

    expect(
      (await freshRead.readFile('source.dart')).text,
      'fresh generation source',
    );
    expect(freshRead.environmentId, freshMutation.environmentId);
    expect(freshRead.sessionId, freshMutation.sessionId);
    expect(replacementProvider.restoreCount, 1);
    await freshMutation.replaceExistingTextFile('source.dart', 'fresh', 'R1');
    expect(replacementProvider.replacements, hasLength(1));
    await expectLater(
      oldRead.readFile('source.dart'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      oldMutation.replaceExistingTextFile('source.dart', 'old', 'R1'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
  });
}

Future<_Fixture> _fixture() async {
  final ProviderId providerId = ProviderId('dev.adele.environment.host-test');
  final _Provider provider = _Provider(providerId);
  final CapabilityRegistry registry = CapabilityRegistry();
  final _Endpoint endpoint = _Endpoint(provider);
  final CapabilityRegistration registration = registry.register(
    provider: ProviderDescriptor(
      id: providerId,
      capability: environmentProviderCapability,
      pluginId: 'dev.adele.plugin.host-test',
      displayName: 'Host Test',
      serviceId: environmentProviderServiceId,
    ),
    endpoint: endpoint,
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
    endpoint,
    registration,
    registry,
    providerId,
  );
}

final class _Fixture {
  const _Fixture(
    this.sessionId,
    this.environmentId,
    this.runtime,
    this.provider,
    this.endpoint,
    this.registration,
    this.registry,
    this.providerId,
  );

  final SessionId sessionId;
  final EnvironmentId environmentId;
  final EnvironmentRuntime runtime;
  final _Provider provider;
  final _Endpoint endpoint;
  final CapabilityRegistration registration;
  final CapabilityRegistry registry;
  final ProviderId providerId;
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
  _Provider(this.providerId, {this.sourceText = 'authorized source'});

  @override
  final ProviderId providerId;
  final String sourceText;
  final List<EnvironmentId> fileEnvironmentIds = <EnvironmentId>[];
  final List<EnvironmentId> directoryEnvironmentIds = <EnvironmentId>[];
  final List<
    ({
      EnvironmentId environmentId,
      String relativePath,
      String replacementText,
      String expectedRevision,
    })
  >
  replacements =
      <
        ({
          EnvironmentId environmentId,
          String relativePath,
          String replacementText,
          String expectedRevision,
        })
      >[];
  int restoreCount = 0;

  List<EnvironmentId> get environmentIds => fileEnvironmentIds;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async => EnvironmentProviderResult(
    providerState: <String, Object?>{'ready': true},
  );

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restoreCount++;
    return EnvironmentProviderResult(providerState: environment.providerState!);
  }

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) async {
    fileEnvironmentIds.add(environmentId);
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: sourceText,
      sizeBytes: sourceText.length,
      revision: 'fixture-revision',
    );
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    replacements.add((
      environmentId: environmentId,
      relativePath: relativePath,
      replacementText: replacementText,
      expectedRevision: expectedRevision,
    ));
    return const EnvironmentTextFileReplacement(
      revision: 'replacement-revision',
    );
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) async {
    directoryEnvironmentIds.add(environmentId);
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: const <EnvironmentDirectoryEntry>[],
    );
  }
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
