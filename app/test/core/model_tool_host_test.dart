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
import 'package:chat_strategy_backend/chat_strategy_backend.dart';
import 'package:command_tools_plugin/command_tools_plugin.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';

void main() {
  test(
    'inference sources use canonical Session and read-only authority',
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
                    sourceRead,
                    isNot(isA<AuthorizedEnvironmentFileMutationFacet>()),
                  );
                  expect(
                    sourceRead,
                    isNot(isA<AuthorizedEnvironmentProcessFacet>()),
                  );
                  expect(
                    await supplied
                        .requireHostService<
                          AuthorizedEnvironmentFileReadFacet
                        >(),
                    same(sourceRead),
                  );
                  await expectLater(
                    supplied
                        .requireHostService<
                          AuthorizedEnvironmentFileMutationFacet
                        >()
                        .then(
                          (AuthorizedEnvironmentFileMutationFacet facet) =>
                              facet.createTextFile(
                                'forbidden.txt',
                                'forbidden',
                              ),
                        ),
                    throwsStateError,
                  );
                  await expectLater(
                    supplied
                        .requireHostService<AuthorizedEnvironmentProcessFacet>()
                        .then(
                          (AuthorizedEnvironmentProcessFacet facet) => facet
                              .runForegroundProcess(_processRequest())
                              .toList(),
                        ),
                    throwsStateError,
                  );
                  await expectLater(
                    supplied
                        .requireHostService<AuthorizedEnvironmentAuthority>(),
                    throwsStateError,
                  );
                  await expectLater(
                    supplied
                        .requireHostService<AuthorizedEnvironmentFileSystem>(),
                    throwsStateError,
                  );
                  await expectLater(
                    supplied.requireHostService<Object>(),
                    throwsStateError,
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
      expect(fixture.provider.creations, isEmpty);
      expect(fixture.provider.replacements, isEmpty);
      expect(fixture.provider.deletions, isEmpty);
      expect(fixture.provider.processEnvironmentIds, isEmpty);

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
      final CanonicalToolArguments arguments = await tool.executable
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
                          toolInvocationId: 'tool-1',
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
    expect(await aliases(), <String>{'search', 'glob'});
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

  for (final paused in [false, true]) {
    test(
      'process facet immediately cancels an ${paused ? 'paused' : 'idle'} provider subscription',
      () async {
        final fixture = await _fixture();
        final process = await SessionModelToolHostContext(
          sessionId: fixture.sessionId,
          environmentRuntime: fixture.runtime,
        ).requireHostService<AuthorizedEnvironmentProcessFacet>();
        final cancelled = Completer<void>();
        final cleanup = Completer<void>();
        final provider = StreamController<EnvironmentProcessEvent>(
          sync: true,
          onCancel: () {
            cancelled.complete();
            return cleanup.future;
          },
        );
        addTearDown(() {
          if (!cleanup.isCompleted) cleanup.complete();
          return provider.close();
        });
        fixture.provider.processStream = provider.stream;
        final stream = process.runForegroundProcess(_processRequest());
        expect(fixture.provider.processEnvironmentIds, isEmpty);
        final subscription = stream.listen((_) {});
        expect(fixture.provider.processEnvironmentIds, [fixture.environmentId]);
        if (paused) {
          subscription.pause();
          expect(provider.isPaused, isTrue);
        }
        final pending = subscription.cancel();
        expect(
          cancelled.isCompleted,
          isTrue,
          reason: 'Cancellation must not wait for provider output.',
        );
        expect(cleanup.isCompleted, isFalse);
        cleanup.complete();
        await pending.timeout(const Duration(seconds: 1));
      },
    );
  }

  test(
    'process facet preserves provider error classification and cancels on failure',
    () async {
      final fixture = await _fixture();
      final process = await SessionModelToolHostContext(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
      ).requireHostService<AuthorizedEnvironmentProcessFacet>();
      for (final error in <Object>[
        ProviderUnavailable(
          capability: environmentProviderCapability,
          providerId: fixture.providerId,
          availableProviderIds: const [],
          stale: true,
        ),
        ProviderUnavailable(
          capability: environmentProviderCapability,
          providerId: fixture.providerId,
          availableProviderIds: const [],
        ),
        ProviderEndpointUnavailable(fixture.providerId),
        const EnvironmentFailure(
          code: 'process_start_failed',
          message: 'Declared failure.',
          details: {},
        ),
        StateError('Unrelated failure'),
      ]) {
        var cancelled = false;
        final provider = StreamController<EnvironmentProcessEvent>(
          sync: true,
          onCancel: () {
            cancelled = true;
          },
        );
        fixture.provider.processStream = provider.stream;
        final Matcher expected = switch (error) {
          ProviderUnavailable(stale: true) =>
            isA<AuthorizedEnvironmentBindingStale>().having(
              (failure) => failure.cause,
              'cause',
              same(error),
            ),
          ProviderUnavailable() || ProviderEndpointUnavailable() =>
            isA<AuthorizedEnvironmentBindingUnavailable>().having(
              (failure) => failure.cause,
              'cause',
              same(error),
            ),
          _ => same(error),
        };
        final failed = expectLater(
          process.runForegroundProcess(_processRequest()).toList(),
          throwsA(expected),
        );
        provider.addError(error);
        await failed;
        expect(cancelled, isTrue);
        await provider.close();
      }
    },
  );

  for (final cleanupMode in ['hangs', 'throws', 'fails asynchronously']) {
    test(
      'process primary failure settles when producer cleanup $cleanupMode',
      () async {
        final fixture = await _fixture();
        final process = await SessionModelToolHostContext(
          sessionId: fixture.sessionId,
          environmentRuntime: fixture.runtime,
        ).requireHostService<AuthorizedEnvironmentProcessFacet>();
        final cleanup = Completer<void>();
        var cancellations = 0;
        final provider = StreamController<EnvironmentProcessEvent>(
          sync: true,
          onCancel: () {
            cancellations++;
            if (cleanupMode == 'throws') throw StateError('cleanup failed');
            if (cleanupMode == 'fails asynchronously') {
              return Future<void>.error(StateError('cleanup failed'));
            }
            return cleanup.future;
          },
        );
        addTearDown(() async {
          if (!cleanup.isCompleted) cleanup.complete();
          await provider.close();
        });
        fixture.provider.processStream = provider.stream;
        final iterator = StreamIterator(
          process.runForegroundProcess(_processRequest()),
        );
        const primary = EnvironmentFailure(
          code: 'process_failed',
          message: 'Primary failure.',
          details: {'evidence': 'preserved'},
        );
        final failed = expectLater(
          iterator.moveNext().timeout(const Duration(seconds: 1)),
          throwsA(same(primary)),
        );
        provider.addError(primary);
        await failed;
        expect(cancellations, 1);
        expect(cleanup.isCompleted, isFalse);
        await iterator.cancel().timeout(const Duration(seconds: 1));
        expect(cancellations, 1);
        expect(process.validateBinding, returnsNormally);
      },
    );
  }

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

  test(
    'shell facets share capture without sharing execution authority',
    () async {
      final provider = _ShellProvider();
      final fixture = await _fixture(selectedProvider: provider);
      final context = SessionModelToolHostContext(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
      );
      final descriptionFuture = context
          .requireHostService<AuthorizedEnvironmentShellDescriptionFacet>();
      final shellFuture = context
          .requireHostService<AuthorizedEnvironmentShellFacet>();
      final process = await context
          .requireHostService<AuthorizedEnvironmentProcessFacet>();
      final read = await context
          .requireHostService<AuthorizedEnvironmentFileReadFacet>();
      final mutation = await context
          .requireHostService<AuthorizedEnvironmentFileMutationFacet>();
      final authority = await context
          .requireHostService<AuthorizedEnvironmentAuthority>();
      final description = await descriptionFuture;
      final shell = await shellFuture;
      expect(description, isNot(isA<AuthorizedEnvironmentShellFacet>()));
      expect(shell, isNot(isA<AuthorizedEnvironmentShellDescriptionFacet>()));
      expect(description, isNot(isA<AuthorizedEnvironmentProcessFacet>()));
      expect(shell, isNot(isA<AuthorizedEnvironmentProcessFacet>()));
      expect(description, isNot(isA<AuthorizedEnvironmentFileReadFacet>()));
      expect(shell, isNot(isA<AuthorizedEnvironmentFileMutationFacet>()));
      expect(
        await context
            .requireHostService<AuthorizedEnvironmentShellDescriptionFacet>(),
        same(description),
      );
      expect(
        await context.requireHostService<AuthorizedEnvironmentShellFacet>(),
        same(shell),
      );
      for (final facet in <AuthorizedEnvironmentAuthority>[
        description,
        shell,
        process,
        read,
        mutation,
        authority,
      ]) {
        expect(facet.sessionId, fixture.sessionId);
        expect(facet.environmentId, fixture.environmentId);
        expect(facet.validateBinding, returnsNormally);
      }
      final profile = await description.describeShell();
      final request = _shellRequest(profile.profileId);
      final stream = shell.runShellCommand(request);
      expect(provider.shellRequests, isEmpty);
      expect((await stream.single).completed!.exitCode, 7);
      expect(provider.shellRequests.single, same(request));
      expect(provider.shellEnvironmentIds, [fixture.environmentId]);
      expect(provider.descriptionEnvironmentIds, [fixture.environmentId]);
      expect(provider.processEnvironmentIds, isEmpty);
      expect(provider.restoreCount, 0);
      expect(() => stream.listen((_) {}), throwsStateError);
    },
  );

  test(
    'shell absence is declared without granting direct process fallback',
    () async {
      final fixture = await _fixture();
      final context = SessionModelToolHostContext(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
      );
      final description = await context
          .requireHostService<AuthorizedEnvironmentShellDescriptionFacet>();
      final shell = await context
          .requireHostService<AuthorizedEnvironmentShellFacet>();
      final unavailable = isA<EnvironmentFailure>().having(
        (error) => error.code,
        'code',
        environmentShellUnavailableCode,
      );
      await expectLater(description.describeShell(), throwsA(unavailable));
      await expectLater(
        shell.runShellCommand(_shellRequest()).toList(),
        throwsA(unavailable),
      );
      expect(fixture.provider.processEnvironmentIds, isEmpty);
      fixture.endpoint.available = false;
      await expectLater(
        description.describeShell(),
        throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
      );
      await expectLater(
        shell.runShellCommand(_shellRequest()).toList(),
        throwsA(isA<AuthorizedEnvironmentBindingUnavailable>()),
      );
    },
  );

  test(
    'shell selection drift preserves the declared failure without execution',
    () async {
      final provider = _ShellProvider();
      final fixture = await _fixture(selectedProvider: provider);
      final context = SessionModelToolHostContext(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
      );
      final description = await context
          .requireHostService<AuthorizedEnvironmentShellDescriptionFacet>();
      final shell = await context
          .requireHostService<AuthorizedEnvironmentShellFacet>();
      final profile = await description.describeShell();
      provider.profile = EnvironmentShellProfile(
        profileId: 'replacement',
        interpreter: '/other/shell',
        dialect: 'other',
      );
      await expectLater(
        shell.runShellCommand(_shellRequest(profile.profileId)).toList(),
        throwsA(
          isA<EnvironmentFailure>().having(
            (error) => error.code,
            'code',
            environmentShellProfileChangedCode,
          ),
        ),
      );
      expect(provider.executions, 0);
      expect(provider.descriptionEnvironmentIds, hasLength(1));
      expect(
        provider.shellRequests.single.expectedProfileId,
        profile.profileId,
      );
      expect(provider.processEnvironmentIds, isEmpty);
    },
  );

  for (final retired in [false, true]) {
    for (final settlement in ['success', 'unavailable', 'transport failure']) {
      test(
        'shell discovery fences $settlement after ${retired ? 'retirement' : 'unavailability'}',
        () async {
          final provider = _ShellProvider();
          final fixture = await _fixture(selectedProvider: provider);
          final description = await SessionModelToolHostContext(
            sessionId: fixture.sessionId,
            environmentRuntime: fixture.runtime,
          ).requireHostService<AuthorizedEnvironmentShellDescriptionFacet>();
          final gate = Completer<EnvironmentShellProfile>();
          provider.description = gate.future;
          final expected = retired
              ? isA<AuthorizedEnvironmentBindingStale>()
              : isA<AuthorizedEnvironmentBindingUnavailable>();
          final pending = expectLater(
            description.describeShell(),
            throwsA(expected),
          );
          expect(provider.descriptionEnvironmentIds, [fixture.environmentId]);
          if (retired) {
            await fixture.registration.close();
          } else {
            fixture.endpoint.available = false;
          }
          switch (settlement) {
            case 'success':
              gate.complete(provider.profile);
            case 'unavailable':
              gate.completeError(
                const EnvironmentFailure(
                  code: environmentShellUnavailableCode,
                  message: 'Selection unavailable.',
                  details: {},
                ),
              );
            default:
              gate.completeError(
                const PluginConnectionClosed('Retired during discovery.'),
              );
          }
          await pending;
          await expectLater(description.describeShell(), throwsA(expected));
          expect(provider.descriptionEnvironmentIds, hasLength(1));
        },
      );
    }
  }

  test(
    'live discovery preserves declared and exact binding failures',
    () async {
      final provider = _ShellProvider();
      final fixture = await _fixture(selectedProvider: provider);
      final description = await SessionModelToolHostContext(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
      ).requireHostService<AuthorizedEnvironmentShellDescriptionFacet>();
      for (final error in <Object>[
        const EnvironmentFailure(
          code: environmentShellUnavailableCode,
          message: 'Unavailable.',
          details: {'reason': 'missing'},
        ),
        ProviderUnavailable(
          capability: environmentProviderCapability,
          providerId: fixture.providerId,
          availableProviderIds: const [],
          stale: true,
        ),
        ProviderEndpointUnavailable(fixture.providerId),
        StateError('Unrelated discovery failure'),
      ]) {
        provider.description = Future<EnvironmentShellProfile>.error(error);
        final Matcher expected = switch (error) {
          ProviderUnavailable() =>
            isA<AuthorizedEnvironmentBindingStale>().having(
              (failure) => failure.cause,
              'cause',
              same(error),
            ),
          ProviderEndpointUnavailable() =>
            isA<AuthorizedEnvironmentBindingUnavailable>().having(
              (failure) => failure.cause,
              'cause',
              same(error),
            ),
          _ => same(error),
        };
        await expectLater(description.describeShell(), throwsA(expected));
      }
    },
  );

  for (final paused in [false, true]) {
    test(
      'shell cancellation reaches ${paused ? 'paused' : 'idle'} provider lazily',
      () async {
        final provider = _ShellProvider();
        final fixture = await _fixture(selectedProvider: provider);
        final shell = await SessionModelToolHostContext(
          sessionId: fixture.sessionId,
          environmentRuntime: fixture.runtime,
        ).requireHostService<AuthorizedEnvironmentShellFacet>();
        final cancelled = Completer<void>();
        final cleanup = Completer<void>();
        final producer = StreamController<EnvironmentProcessEvent>(
          sync: true,
          onCancel: () {
            cancelled.complete();
            return cleanup.future;
          },
        );
        addTearDown(() {
          if (!cleanup.isCompleted) cleanup.complete();
          return producer.close();
        });
        provider.shellStream = producer.stream;
        final stream = shell.runShellCommand(_shellRequest());
        expect(provider.shellRequests, isEmpty);
        final subscription = stream.listen((_) {});
        expect(provider.shellEnvironmentIds, [fixture.environmentId]);
        if (paused) {
          subscription.pause();
          expect(producer.isPaused, isTrue);
        }
        final pending = subscription.cancel();
        expect(cancelled.isCompleted, isTrue);
        expect(cleanup.isCompleted, isFalse);
        cleanup.complete();
        await pending.timeout(const Duration(seconds: 1));
      },
    );
  }

  test(
    'shell facets retain old generation when a fresh context restores',
    () async {
      final provider = _ShellProvider();
      final fixture = await _fixture(selectedProvider: provider);
      final oldContext = SessionModelToolHostContext(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
      );
      final oldDescription = await oldContext
          .requireHostService<AuthorizedEnvironmentShellDescriptionFacet>();
      final oldShell = await oldContext
          .requireHostService<AuthorizedEnvironmentShellFacet>();
      final deferred = oldShell.runShellCommand(_shellRequest());
      await fixture.registration.close();
      final replacement = _ShellProvider();
      final registration = fixture.registry.register(
        provider: ProviderDescriptor(
          id: fixture.providerId,
          capability: environmentProviderCapability,
          pluginId: 'dev.adele.plugin.host-test',
          displayName: 'Replacement',
          serviceId: environmentProviderServiceId,
        ),
        endpoint: _Endpoint(replacement),
      );
      addTearDown(registration.close);
      final fresh = SessionModelToolHostContext(
        sessionId: fixture.sessionId,
        environmentRuntime: fixture.runtime,
      );
      final description = await fresh
          .requireHostService<AuthorizedEnvironmentShellDescriptionFacet>();
      final shell = await fresh
          .requireHostService<AuthorizedEnvironmentShellFacet>();
      expect(
        (await description.describeShell()).profileId,
        replacement.profile.profileId,
      );
      expect(
        (await shell.runShellCommand(_shellRequest()).single)
            .completed!
            .exitCode,
        7,
      );
      expect(replacement.restoreCount, 1);
      expect(description.environmentId, fixture.environmentId);
      expect(shell.sessionId, fixture.sessionId);
      await expectLater(
        oldDescription.describeShell(),
        throwsA(isA<AuthorizedEnvironmentBindingStale>()),
      );
      await expectLater(
        deferred.toList(),
        throwsA(isA<AuthorizedEnvironmentBindingStale>()),
      );
      expect(provider.descriptionEnvironmentIds, isEmpty);
      expect(provider.shellRequests, isEmpty);
      expect(
        await oldContext.requireHostService<AuthorizedEnvironmentShellFacet>(),
        same(oldShell),
      );
    },
  );

  for (final paused in [false, true]) {
    test(
      'exact shell provider retirement cancels ${paused ? 'paused' : 'idle'} streams',
      () async {
        final provider = _ShellProvider();
        final fixture = await _fixture(selectedProvider: provider);
        final shell = await SessionModelToolHostContext(
          sessionId: fixture.sessionId,
          environmentRuntime: fixture.runtime,
        ).requireHostService<AuthorizedEnvironmentShellFacet>();
        final cancelled = Completer<void>();
        final producer = StreamController<EnvironmentProcessEvent>(
          sync: true,
          onCancel: cancelled.complete,
        );
        addTearDown(producer.close);
        provider.shellStream = producer.stream;
        final errors = <Object>[];
        final done = Completer<void>();
        final subscription = shell
            .runShellCommand(_shellRequest())
            .listen((_) {}, onError: errors.add, onDone: done.complete);
        addTearDown(subscription.cancel);
        if (paused) subscription.pause();
        var retirements = 0;
        final detach = shell.onRetire(() => retirements++);
        await fixture.registration.close();
        await cancelled.future.timeout(const Duration(seconds: 1));
        expect(retirements, 1);
        detach();
        detach();
        if (paused) subscription.resume();
        await done.future.timeout(const Duration(seconds: 1));
        expect(errors, [isA<AuthorizedEnvironmentBindingStale>()]);
        expect(
          () => shell.onRetire(() {}),
          throwsA(isA<AuthorizedEnvironmentBindingStale>()),
        );
      },
    );
  }

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

Future<_Fixture> _fixture({_Provider? selectedProvider}) async {
  final ProviderId providerId = ProviderId('dev.adele.environment.host-test');
  final _Provider provider = selectedProvider ?? _Provider(providerId);
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
  final ExtensionRegistration strategyActivation = ChatStrategyPlugin(
    maxModelInvocations: 8,
  ).activate(extensions);
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

class _Provider implements EnvironmentProvider {
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

EnvironmentShellCommandRequest _shellRequest([
  String profileId = 'profile:one',
]) => EnvironmentShellCommandRequest(
  command: '  printf "a | b" && other\n',
  expectedProfileId: profileId,
  relativeWorkingDirectory: 'nested dir',
  timeoutSeconds: 1800,
);

final class _ShellProvider extends _Provider
    implements EnvironmentShellProvider {
  _ShellProvider() : super(ProviderId('dev.adele.environment.host-test'));

  EnvironmentShellProfile profile = EnvironmentShellProfile(
    profileId: 'profile:one',
    interpreter: '/selected/shell',
    dialect: 'custom',
  );
  Future<EnvironmentShellProfile>? description;
  final descriptionEnvironmentIds = <EnvironmentId>[];
  final shellEnvironmentIds = <EnvironmentId>[];
  final shellRequests = <EnvironmentShellCommandRequest>[];
  Stream<EnvironmentProcessEvent>? shellStream;
  int executions = 0;

  @override
  Future<EnvironmentShellProfile> describeShell(EnvironmentId environmentId) {
    descriptionEnvironmentIds.add(environmentId);
    return description ?? Future.value(profile);
  }

  @override
  Stream<EnvironmentProcessEvent> runShellCommand(
    EnvironmentId environmentId,
    EnvironmentShellCommandRequest request,
  ) {
    shellEnvironmentIds.add(environmentId);
    shellRequests.add(request);
    if (request.expectedProfileId != profile.profileId) {
      throw const EnvironmentFailure(
        code: environmentShellProfileChangedCode,
        message: 'Selection changed.',
        details: {},
      );
    }
    executions++;
    return shellStream ??
        Stream.value(
          EnvironmentProcessEvent(
            kind: EnvironmentProcessEventKind.completed,
            output: null,
            completed: EnvironmentProcessCompleted(
              termination: EnvironmentProcessTermination.exited,
              exitCode: 7,
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
