import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_desktop/core/inference_context_host.dart';
import 'package:adele_desktop/core/model_tool_host.dart';
import 'package:adele_desktop/core/product_lifecycle.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_orchestration/adele_orchestration.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:chat_strategy_plugin/chat_strategy_plugin.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

void main() {
  test(
    'inference sources use canonical Session and tool host authority',
    () async {
      final _Fixture fixture = await _fixture();
      final Session session = fixture.runtime.store.session(fixture.sessionId)!;
      final RunId runId = RunId('context-authority-run');
      final SessionInferenceContextSourceContext context =
          SessionInferenceContextSourceContext(
            session: session,
            runId: runId,
            environmentRuntime: fixture.runtime,
          );
      final SessionModelToolHostContext toolContext =
          SessionModelToolHostContext(
            sessionId: session.id,
            environmentRuntime: fixture.runtime,
          );
      final AuthorizedEnvironmentFileReadFacet toolRead = await toolContext
          .requireHostService<AuthorizedEnvironmentFileReadFacet>();
      // Another published Environment is not selectable through source services.
      final Task otherTask = Task(
        id: TaskId('other-task'),
        projectId: fixture.runtime.store.task(session.taskId)!.projectId,
        title: 'Not authorized for this Session',
      );
      fixture.runtime.store.publishTaskWithPrimaryEnvironment(
        otherTask,
        Environment(
          id: EnvironmentId('other-environment'),
          taskId: otherTask.id,
          role: EnvironmentRole.primary,
          providerId: fixture.providerId,
          providerState: const <String, Object?>{'ready': true},
        ),
      );
      final ExtensionRegistry extensions = ExtensionRegistry();
      late AuthorizedEnvironmentFileReadFacet sourceRead;
      addTearDown(
        extensions
            .register(
              point: inferenceContextSources,
              id: ExtensionId('dev.adele.test.authorized-context'),
              value: InferenceContextSourceContribution(
                failureMode: InferenceContextFailureMode.required,
                snapshot: (InferenceContextSourceContext supplied) async {
                  expect(supplied.session, same(session));
                  expect(supplied.runId, runId);
                  expect(supplied.session.strategyId, chatStrategyId);
                  sourceRead = await supplied
                      .requireHostService<AuthorizedEnvironmentFileReadFacet>();
                  expect(sourceRead.sessionId, toolRead.sessionId);
                  expect(sourceRead.environmentId, toolRead.environmentId);
                  expect(sourceRead.environmentId, fixture.environmentId);
                  expect(
                    await supplied
                        .requireHostService<
                          AuthorizedEnvironmentFileReadFacet
                        >(),
                    same(sourceRead),
                  );
                  await expectLater(
                    supplied.requireHostService<ExtensionRegistry>(),
                    throwsStateError,
                  );
                  await expectLater(
                    supplied.requireHostService<EnvironmentRuntime>(),
                    throwsStateError,
                  );
                  await expectLater(
                    supplied.requireHostService<ModelPort>(),
                    throwsStateError,
                  );
                  await expectLater(
                    supplied.requireHostService<ToolCatalog>(),
                    throwsStateError,
                  );
                  final EnvironmentTextFile file = await sourceRead.readFile(
                    'fixture.txt',
                  );
                  return <InferenceContextMaterial>[
                    InferenceInstructionMaterial(
                      key: 'fixture-guidance',
                      text: file.text,
                      revision: file.revision,
                    ),
                  ];
                },
              ),
            )
            .close,
      );
      final InferenceContextSnapshot snapshot =
          await InferenceContextComposer(extensions).compose(
            strategyMaterial: StrategyInferenceMaterial(
              input: const <SemanticModelInputItem>[],
            ),
            sourceContext: context,
          );
      expect(renderInferenceInstructions(snapshot), 'authorized source');
      expect(fixture.provider.fileEnvironmentIds, <EnvironmentId>[
        fixture.environmentId,
      ]);
      expect(fixture.provider.restoreCount, 0);

      await fixture.registration.close();
      for (final AuthorizedEnvironmentFileReadFacet read in [
        toolRead,
        sourceRead,
      ]) {
        await expectLater(
          read.readFile('fixture.txt'),
          throwsA(isA<AuthorizedEnvironmentBindingStale>()),
        );
      }
      // Captured text is independent of the service or source's live authority.
      expect(renderInferenceInstructions(snapshot), 'authorized source');
      expect(
        () => SessionInferenceContextSourceContext(
          session: Session(
            id: session.id,
            taskId: otherTask.id,
            strategyId: session.strategyId,
          ),
          runId: runId,
          environmentRuntime: fixture.runtime,
        ),
        throwsArgumentError,
      );
    },
  );

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
      final MaterializedTool createFile = tools.byAlias('create_file')!;
      final MaterializedTool deleteFile = tools.byAlias('delete_file')!;
      final Object? properties =
          tool.modelDefinition.argumentsSchema['properties'];
      expect(properties, isA<Map<String, Object?>>());
      expect((properties! as Map<String, Object?>).keys, <String>[
        'relativePath',
        'startLine',
        'lineCount',
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
        createFile.executable.validateBinding,
        throwsA(isA<StaleToolBindingException>()),
      );
      expect(
        deleteFile.executable.validateBinding,
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

  test('stock tool plugins activate and compose independently', () async {
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
    expect(await aliases(), <String>{
      'read_file',
      'apply_patch',
      'create_file',
      'delete_file',
    });
    await filesystem.close();

    final ExtensionRegistration search = const SearchToolsPlugin().activate(
      extensions,
    );
    expect(await aliases(), <String>{'search'});
    await search.close();

    final ExtensionRegistration command = const CommandToolsPlugin().activate(
      extensions,
    );
    expect(await aliases(), <String>{'run_command'});
    final ExtensionRegistration bothFilesystem = const FilesystemToolsPlugin()
        .activate(extensions);
    expect(await aliases(), <String>{
      'run_command',
      'read_file',
      'apply_patch',
      'create_file',
      'delete_file',
    });
    await command.close();
    await bothFilesystem.close();
  });

  test('authorized facets share Session Environment and generation', () async {
    final _Fixture fixture = await _fixture();
    final SessionModelToolHostContext context = SessionModelToolHostContext(
      sessionId: fixture.sessionId,
      environmentRuntime: fixture.runtime,
    );
    final AuthorizedEnvironmentAuthority environmentAuthority = await context
        .requireHostService<AuthorizedEnvironmentAuthority>();
    final AuthorizedEnvironmentFileSystem authority = await context
        .requireHostService<AuthorizedEnvironmentFileSystem>();
    final AuthorizedEnvironmentFileReadFacet read = await context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet mutation = await context
        .requireHostService<AuthorizedEnvironmentFileMutationFacet>();
    final AuthorizedEnvironmentProcessFacet process = await context
        .requireHostService<AuthorizedEnvironmentProcessFacet>();

    expect(environmentAuthority, same(authority));
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
      await context.requireHostService<AuthorizedEnvironmentProcessFacet>(),
      same(process),
    );
    expect(
      <SessionId>{
        authority.sessionId,
        read.sessionId,
        mutation.sessionId,
        process.sessionId,
      },
      <SessionId>{fixture.sessionId},
    );
    expect(
      <EnvironmentId>{
        authority.environmentId,
        read.environmentId,
        mutation.environmentId,
        process.environmentId,
      },
      <EnvironmentId>{fixture.environmentId},
    );

    final EnvironmentDirectoryListing listing = await read.readDirectory(
      'nested',
    );
    final EnvironmentTextFileCreation creation = await mutation.createTextFile(
      'created.dart',
      'created',
    );
    final EnvironmentTextFileReplacement replacement = await mutation
        .replaceExistingTextFile('source.dart', 'replacement', 'R1');
    await mutation.deleteExistingTextFile('obsolete.dart', 'R-delete');
    final List<EnvironmentProcessEvent> processEvents = await process
        .runForegroundProcess(_processRequest())
        .toList();
    expect(listing.relativePath, 'nested');
    expect(creation.revision, 'creation-revision');
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
    expect(fixture.provider.creations.single, (
      environmentId: fixture.environmentId,
      relativePath: 'created.dart',
      text: 'created',
    ));
    expect(fixture.provider.deletions.single, (
      environmentId: fixture.environmentId,
      relativePath: 'obsolete.dart',
      expectedRevision: 'R-delete',
    ));
    expect(fixture.provider.processEnvironmentIds, <EnvironmentId>[
      fixture.environmentId,
    ]);
    expect(processEvents.single.completed!.exitCode, 0);

    final Stream<EnvironmentProcessEvent> deferredProcess = process
        .runForegroundProcess(_processRequest());
    await fixture.registration.close();
    await expectLater(
      read.readFile('source.dart'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      mutation.replaceExistingTextFile('source.dart', 'other', 'R2'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      mutation.createTextFile('other.dart', 'other'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      mutation.deleteExistingTextFile('source.dart', 'R2'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      deferredProcess,
      emitsError(isA<AuthorizedEnvironmentBindingStale>()),
    );
    expect(fixture.provider.processEnvironmentIds, hasLength(1));
  });

  test('provider unavailability affects every facet consistently', () async {
    final _Fixture fixture = await _fixture();
    final SessionModelToolHostContext context = SessionModelToolHostContext(
      sessionId: fixture.sessionId,
      environmentRuntime: fixture.runtime,
    );
    final AuthorizedEnvironmentFileReadFacet read = await context
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet mutation = await context
        .requireHostService<AuthorizedEnvironmentFileMutationFacet>();
    final AuthorizedEnvironmentProcessFacet process = await context
        .requireHostService<AuthorizedEnvironmentProcessFacet>();
    fixture.endpoint.available = false;

    await expectLater(
      read.readDirectory('nested'),
      throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
    );
    await expectLater(
      mutation.replaceExistingTextFile('source.dart', 'other', 'R1'),
      throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
    );
    await expectLater(
      mutation.createTextFile('other.dart', 'other'),
      throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
    );
    await expectLater(
      mutation.deleteExistingTextFile('source.dart', 'R1'),
      throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
    );
    await expectLater(
      process.runForegroundProcess(_processRequest()),
      emitsError(isA<AuthorizedEnvironmentBindingUnavailable>()),
    );
  });

  test('active process stream translates retired generation closure', () async {
    final _Fixture fixture = await _fixture();
    final SessionModelToolHostContext context = SessionModelToolHostContext(
      sessionId: fixture.sessionId,
      environmentRuntime: fixture.runtime,
    );
    final AuthorizedEnvironmentProcessFacet process = await context
        .requireHostService<AuthorizedEnvironmentProcessFacet>();
    final StreamController<EnvironmentProcessEvent> providerStream =
        StreamController<EnvironmentProcessEvent>();
    fixture.provider.processStream = providerStream.stream;
    final StreamIterator<EnvironmentProcessEvent> events =
        StreamIterator<EnvironmentProcessEvent>(
          process.runForegroundProcess(_processRequest()),
        );

    final Future<bool> progress = events.moveNext();
    providerStream.add(
      EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.output,
        output: EnvironmentProcessOutput(
          stream: EnvironmentProcessOutputStream.stdout,
          text: 'started',
        ),
        completed: null,
      ),
    );
    expect(await progress, isTrue);
    expect(events.current.output!.text, 'started');

    await fixture.registration.close();
    final Future<bool> afterRetirement = events.moveNext();
    const PluginConnectionClosed transportFailure = PluginConnectionClosed(
      'Generation A closed during the process stream.',
    );
    providerStream.addError(transportFailure);

    await expectLater(
      afterRetirement,
      throwsA(
        isA<AuthorizedEnvironmentBindingStale>().having(
          (AuthorizedEnvironmentBindingStale error) => error.cause,
          'cause',
          same(transportFailure),
        ),
      ),
    );
    await events.cancel();
    await providerStream.close();
  });

  test('fresh host context receives fresh provider facet bindings', () async {
    final _Fixture fixture = await _fixture();
    final Session session = fixture.runtime.store.session(fixture.sessionId)!;
    SessionInferenceContextSourceContext inferenceContext() =>
        SessionInferenceContextSourceContext(
          session: session,
          runId: RunId('same-run'),
          environmentRuntime: fixture.runtime,
        );
    final AuthorizedEnvironmentFileReadFacet oldSourceRead =
        await inferenceContext()
            .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final SessionModelToolHostContext oldContext = SessionModelToolHostContext(
      sessionId: fixture.sessionId,
      environmentRuntime: fixture.runtime,
    );
    final AuthorizedEnvironmentFileReadFacet oldRead = await oldContext
        .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    final AuthorizedEnvironmentFileMutationFacet oldMutation = await oldContext
        .requireHostService<AuthorizedEnvironmentFileMutationFacet>();
    final AuthorizedEnvironmentProcessFacet oldProcess = await oldContext
        .requireHostService<AuthorizedEnvironmentProcessFacet>();
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
    final AuthorizedEnvironmentProcessFacet freshProcess = await freshContext
        .requireHostService<AuthorizedEnvironmentProcessFacet>();
    final AuthorizedEnvironmentFileReadFacet freshSourceRead =
        await inferenceContext()
            .requireHostService<AuthorizedEnvironmentFileReadFacet>();
    expect(
      (await freshSourceRead.readFile('fixture.txt')).text,
      'fresh generation source',
    );
    expect(freshSourceRead.environmentId, fixture.environmentId);
    await expectLater(
      oldSourceRead.readFile('fixture.txt'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );

    expect(
      (await freshRead.readFile('source.dart')).text,
      'fresh generation source',
    );
    expect(freshRead.environmentId, freshMutation.environmentId);
    expect(freshRead.environmentId, freshProcess.environmentId);
    expect(freshRead.sessionId, freshMutation.sessionId);
    expect(freshRead.sessionId, freshProcess.sessionId);
    expect(replacementProvider.restoreCount, 1);
    await freshMutation.createTextFile('fresh.dart', 'fresh creation');
    await freshMutation.replaceExistingTextFile('source.dart', 'fresh', 'R1');
    await freshMutation.deleteExistingTextFile('fresh.dart', 'R-created');
    expect(replacementProvider.creations, hasLength(1));
    expect(replacementProvider.replacements, hasLength(1));
    expect(replacementProvider.deletions, hasLength(1));
    expect(
      (await freshProcess.runForegroundProcess(_processRequest()).single)
          .completed!
          .exitCode,
      0,
    );
    await expectLater(
      oldRead.readFile('source.dart'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      oldMutation.replaceExistingTextFile('source.dart', 'old', 'R1'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      oldMutation.createTextFile('old.dart', 'old'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      oldMutation.deleteExistingTextFile('source.dart', 'R1'),
      throwsA(isA<AuthorizedEnvironmentBindingStale>()),
    );
    await expectLater(
      oldProcess.runForegroundProcess(_processRequest()),
      emitsError(isA<AuthorizedEnvironmentBindingStale>()),
    );
  });
}

EnvironmentForegroundProcessRequest _processRequest() =>
    EnvironmentForegroundProcessRequest(
      program: 'fixture',
      arguments: const <String>[],
      relativeWorkingDirectory: '',
      timeoutSeconds: 5,
    );

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
  final ExtensionRegistry extensions = ExtensionRegistry();
  final ExtensionRegistration strategyActivation = ChatStrategyPlugin()
      .activate(extensions);
  addTearDown(strategyActivation.close);
  final InMemoryProductStore store = InMemoryProductStore();
  final ProductLifecycleCoordinator lifecycle = ProductLifecycleCoordinator(
    store: store,
    registry: registry,
    extensions: extensions,
    ids: const _Ids(),
    providerForBinding: (binding) => binding.endpointAs<_Endpoint>().provider,
  );
  final Project project = lifecycle.createProject(Uri.parse('file:///source'));
  final TaskCreationResult created = await lifecycle.createTask(
    projectId: project.id,
    title: 'Host tools',
    providerId: providerId,
  );
  final Session session = lifecycle.createSession(
    taskId: created.task.id,
    strategyId: chatStrategyId,
  );
  return _Fixture(
    session.id,
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
  final List<EnvironmentId> processEnvironmentIds = <EnvironmentId>[];
  Stream<EnvironmentProcessEvent>? processStream;
  final List<({EnvironmentId environmentId, String relativePath, String text})>
  creations =
      <({EnvironmentId environmentId, String relativePath, String text})>[];
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
  final List<
    ({
      EnvironmentId environmentId,
      String relativePath,
      String expectedRevision,
    })
  >
  deletions =
      <
        ({
          EnvironmentId environmentId,
          String relativePath,
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
  Future<EnvironmentTextFileCreation> createTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String text,
  ) async {
    creations.add((
      environmentId: environmentId,
      relativePath: relativePath,
      text: text,
    ));
    return EnvironmentTextFileCreation(revision: 'creation-revision');
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
  Future<void> deleteExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String expectedRevision,
  ) async {
    deletions.add((
      environmentId: environmentId,
      relativePath: relativePath,
      expectedRevision: expectedRevision,
    ));
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

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
  ) {
    processEnvironmentIds.add(environmentId);
    return processStream ??
        Stream<EnvironmentProcessEvent>.value(
          EnvironmentProcessEvent(
            kind: EnvironmentProcessEventKind.completed,
            output: null,
            completed: EnvironmentProcessCompleted(
              termination: EnvironmentProcessTermination.exited,
              exitCode: 0,
              stdoutTruncated: false,
              stderrTruncated: false,
            ),
          ),
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
  SessionId nextSessionId() => SessionId('session-1');

  @override
  TaskId nextTaskId() => TaskId('task-1');
}
