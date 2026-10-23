import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:adele_project_storage/adele_project_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:git_backend/git_backend.dart';
import 'package:git_backend/src/git_task_anchor_schema.dart';
import 'package:plugin_runtime/plugin_runtime.dart';
import 'package:test/test.dart';

void main() {
  late String repository;
  late String dartaotruntime;
  late File hostArtifact;
  late File pluginArtifact;

  setUpAll(() async {
    repository = Directory.current.parent.parent.parent.parent.path;
    final Directory artifacts = Directory(
      '$repository/.dart_tool/adele/integration/git',
    )..createSync(recursive: true);
    final String dart = Platform.resolvedExecutable;
    dartaotruntime = '${File(dart).parent.path}/dartaotruntime';
    hostArtifact = File('${artifacts.path}/host.aot');
    pluginArtifact = File('${artifacts.path}/git.aot');
    await Future.wait<void>(<Future<void>>[
      _compile(
        dart,
        '$repository/packages/plugin_backend_host/bin/adele_backend_host.dart',
        hostArtifact.path,
        repository,
      ),
      _compile(
        dart,
        '$repository/plugins/git/packages/backend/bin/'
        'git_backend.dart',
        pluginArtifact.path,
        repository,
      ),
    ]);
  });

  test(
    'AOT buffered processes preserve bytes, selected Environments and bounded failures',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final registry = CapabilityRegistry();
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: await host.startPlugin(
          pluginId: gitPluginId,
          artifactUri: pluginArtifact.uri,
        ),
        registry: registry,
      );
      addTearDown(activation.close);
      final binding = registry.resolve(
        environmentProviderCapability,
        providerId: ProviderId(gitWorktreeEnvironmentProviderId),
      );
      final provider = GeneratedEnvironmentProvider(
        providerId: binding.provider.id,
        service: EnvironmentProviderServiceClient(binding.requestChannel),
      );
      final project = Project(
        id: ProjectId('buffered-project'),
        sourceLocation: fixture.projectSourceA.uri,
      );
      final task = Task(
        id: TaskId('buffered-task'),
        projectId: project.id,
        title: 'Buffered processes',
      );
      final child =
          '$repository/plugins/git/packages/backend/'
          'test/fixtures/buffered_process_child.dart';
      EnvironmentBufferedProcessRequest probe(
        List<String> arguments, {
        List<int> stdin = const [],
        int timeoutSeconds = 10,
      }) => EnvironmentBufferedProcessRequest(
        program: Platform.resolvedExecutable,
        arguments: [child, ...arguments],
        relativeWorkingDirectory: '',
        timeoutSeconds: timeoutSeconds,
        stdinBase64: encodeEnvironmentProcessBytes(
          stdin,
          maximumBytes: environmentBufferedProcessStdinLimit,
        ),
      );
      const binary = [0, 255, 128, 192, 175, 13, 10, 27, 91, 50, 74, 1, 9, 127];
      final stdin = List<int>.generate(
        environmentBufferedProcessStdinLimit,
        (i) => binary[i % binary.length],
      );
      final primary = EnvironmentId('buffered-primary');
      final additional = EnvironmentId('buffered-additional');
      for (final id in [primary, additional]) {
        final environment = Environment(
          id: id,
          taskId: task.id,
          role: id == primary
              ? EnvironmentRole.primary
              : EnvironmentRole.additional,
          providerId: provider.providerId,
          providerState: null,
        );
        final established = await provider.establish(
          LocalEnvironment(project: project, task: task, value: environment),
        );
        final worktree = Directory(
          '${fixture.projectSourceA.path}/'
          '${established.providerState['worktreeRelativePath']}',
        );
        final root = Directory(
          '${worktree.path}/${established.providerState['sourceRelativePath']}',
        );
        final names = ['line\nbreak.txt', 'space name.txt', '${id.value}.txt']
          ..sort();
        for (final name in names) {
          await File('${root.path}/$name').writeAsBytes(binary);
        }
        await _git(root, ['add', '--', ...names]);
        final index = File(
          await _git(root, [
            'rev-parse',
            '--path-format=absolute',
            '--git-path',
            'index',
          ]),
        );
        final indexBefore = await index.readAsBytes();
        final refsBefore = await _git(root, ['show-ref']);

        final echoed = await provider.runBufferedProcess(
          id,
          probe(['echo', '23'], stdin: stdin),
        );
        expect(echoed.exitCode, 23);
        expect(
          decodeEnvironmentProcessBytes(
            echoed.stdoutBase64,
            maximumBytes: environmentBufferedProcessStdoutLimit,
          ),
          stdin,
        );
        expect(
          decodeEnvironmentProcessBytes(
            echoed.stderrBase64,
            maximumBytes: environmentBufferedProcessStderrLimit,
          ),
          [0, 255, 128, 13, 10, 27, 91, 50, 74],
        );
        Future<EnvironmentBufferedProcessResult> git(
          List<String> arguments, {
          List<int> input = const [],
        }) => provider.runBufferedProcess(
          id,
          EnvironmentBufferedProcessRequest(
            program: 'git',
            arguments: arguments,
            relativeWorkingDirectory: '',
            timeoutSeconds: 10,
            stdinBase64: encodeEnvironmentProcessBytes(
              input,
              maximumBytes: environmentBufferedProcessStdinLimit,
            ),
          ),
        );
        final identity = await git([
          'rev-parse',
          '--show-toplevel',
          '--show-prefix',
        ]);
        expect(identity.exitCode, 0);
        expect(
          base64Decode(identity.stdoutBase64),
          utf8.encode('${worktree.path}\nproject-source/\n'),
        );
        expect(identity.stderrBase64, isEmpty);
        final paths = await git(['ls-files', '--cached', '-z', '--', '*.txt']);
        expect(paths.exitCode, 0);
        expect(paths.stderrBase64, isEmpty);
        expect(
          base64Decode(paths.stdoutBase64),
          utf8.encode('${names.join('\x00')}\x00'),
        );
        final hash = await git(['hash-object', '--stdin'], input: binary);
        final expectedHash = sha1.convert([
          ...ascii.encode('blob ${binary.length}\x00'),
          ...binary,
        ]).toString();
        expect(hash.exitCode, 0);
        expect(
          base64Decode(hash.stdoutBase64),
          ascii.encode('$expectedHash\n'),
        );
        expect(hash.stderrBase64, isEmpty);
        final diagnostic = await git([
          'rev-parse',
          '--verify',
          'refs/heads/adele-missing-ref',
        ]);
        expect(diagnostic.exitCode, 128);
        expect(diagnostic.stdoutBase64, isEmpty);
        expect(base64Decode(diagnostic.stderrBase64), isNotEmpty);
        expect(await index.readAsBytes(), indexBefore);
        expect(await _git(root, ['show-ref']), refsBefore);
      }

      // Both maximum binary outputs must fit in one complete generated reply.
      final maximum = await provider.runBufferedProcess(
        additional,
        probe([
          'outputs',
          '$environmentBufferedProcessStdoutLimit',
          '$environmentBufferedProcessStderrLimit',
          '${stdin.length}',
        ], stdin: stdin),
      );
      expect(maximum.exitCode, 0);
      expect(
        decodeEnvironmentProcessBytes(
          maximum.stdoutBase64,
          maximumBytes: environmentBufferedProcessStdoutLimit,
        ),
        List<int>.generate(
          environmentBufferedProcessStdoutLimit,
          (i) => i % 256,
        ),
      );
      expect(
        decodeEnvironmentProcessBytes(
          maximum.stderrBase64,
          maximumBytes: environmentBufferedProcessStderrLimit,
        ),
        List<int>.generate(
          environmentBufferedProcessStderrLimit,
          (i) => i % 256,
        ),
      );
      await expectLater(
        provider.runBufferedProcess(
          EnvironmentId('not-materialized'),
          probe(['empty']),
        ),
        throwsA(_failureWithCode('environment_not_live')),
      );
      await expectLater(
        provider.runBufferedProcess(
          additional,
          EnvironmentBufferedProcessRequest(
            program: '${fixture.container.path}/missing-executable',
            arguments: const [],
            relativeWorkingDirectory: '',
            timeoutSeconds: 10,
            stdinBase64: '',
          ),
        ),
        throwsA(_failureWithCode('process_executable_not_found')),
      );
      await expectLater(
        provider.runBufferedProcess(
          additional,
          probe(['wait'], timeoutSeconds: 1),
        ),
        throwsA(_failureWithCode('process_timed_out')),
      );
      await expectLater(
        provider.runBufferedProcess(
          additional,
          probe(['refuse'], stdin: stdin),
        ),
        throwsA(_failureWithCode('process_stdin_failed')),
      );
      for (final sizes in [
        [environmentBufferedProcessStdoutLimit + 1, 0],
        [0, environmentBufferedProcessStderrLimit + 1],
      ]) {
        await expectLater(
          provider.runBufferedProcess(
            additional,
            probe(['outputs', '${sizes[0]}', '${sizes[1]}']),
          ),
          throwsA(_failureWithCode('process_output_overflow')),
        );
      }
      final recovered = await provider.runBufferedProcess(
        primary,
        probe(['empty']),
      );
      expect(recovered.exitCode, 0);
      expect(recovered.stdoutBase64, isEmpty);
      expect(recovered.stderrBase64, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 45)),
    skip: !Platform.isLinux ? 'Buffered Git processes require Linux.' : false,
  );

  test(
    'stock AOT routes separate process-only snapshots and review with anchor storage',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final storage = _DiffStorage();
      final connection = await host.startPlugin(
        pluginId: gitPluginId,
        artifactUri: pluginArtifact.uri,
        createInfrastructureServices: (owner) {
          expect(owner.pluginId, gitPluginId);
          storage.validate = owner.validateInfrastructureContext;
          return {
            projectStorageServiceId: ProjectStorageServiceDispatcher(storage),
          };
        },
      );
      final registry = CapabilityRegistry();
      final activation = await PluginCapabilityActivation.registerAdvertised(
        connection: connection,
        registry: registry,
      );
      final environmentBinding = registry.resolve(
        environmentProviderCapability,
        providerId: ProviderId(gitWorktreeEnvironmentProviderId),
      );
      final changes = registry.resolve(
        changeSetSourceCapability,
        providerId: ProviderId(gitChangeSetSourceProviderId),
      );
      final approvals = registry.resolve(
        reviewApprovalCapability,
        providerId: ProviderId(gitReviewApprovalProviderId),
      );
      expect(connection.capabilityExposures, hasLength(3));
      expect(changes.provider.serviceId, changeSetSourceServiceId);
      expect(approvals.provider.id.value, 'dev.adele.git.review-approval');
      expect(approvals.provider.serviceId, reviewApprovalHandlerServiceId);
      expect(
        approvals.provider.capability.id.value,
        'adele.diff.review-approval',
      );
      expect(approvals.provider.capability.majorVersion, 1);
      for (final binding in [changes, approvals]) {
        expect(activation.associationFor(binding), isNull);
        expect(activation.isEnvironmentBound(binding), isTrue);
        final exposure = connection.capabilityExposures.singleWhere(
          (value) => value.providerId == binding.provider.id.value,
        );
        expect(exposure.environmentBound, isTrue);
        expect(exposure.association, isNull);
        expect(exposure.environmentHostServices, [
          AdeleEnvironmentHostService.bufferedProcess,
        ]);
      }
      final provider = GeneratedEnvironmentProvider(
        providerId: environmentBinding.provider.id,
        service: EnvironmentProviderServiceClient(
          environmentBinding.requestChannel,
        ),
      );
      final project = Project(
        id: ProjectId('diff-project'),
        sourceLocation: fixture.projectSourceA.uri,
      );
      final task = Task(
        id: TaskId('diff-task'),
        projectId: project.id,
        title: 'Diff',
      );
      final roots = <String, Directory>{};
      for (final name in ['primary', 'additional']) {
        final environment = Environment(
          id: EnvironmentId(name),
          taskId: task.id,
          role: name == 'primary'
              ? EnvironmentRole.primary
              : EnvironmentRole.additional,
          providerId: provider.providerId,
          providerState: null,
        );
        final established = await provider.establish(
          LocalEnvironment(project: project, task: task, value: environment),
        );
        expect(
          established.providerState.containsKey('baselineCommit'),
          isFalse,
        );
        expect(established.initialState!.schema, gitTaskAnchorSchema);
        storage.anchors[name] =
            established.initialState!.inserts.single.parameters;
        roots[name] = Directory(
          '${fixture.projectSourceA.path}/${established.providerState['worktreeRelativePath']}/${established.providerState['sourceRelativePath']}',
        );
        await provider.createTextFile(
          environment.id,
          'same.txt',
          '$name content\n',
        );
        if (name == 'primary') {
          await _git(fixture.projectSourceA, [
            'commit',
            '--allow-empty',
            '-m',
            'Independent additional anchor',
          ]);
        }
      }
      expect(
        storage.anchors['primary']![':baseline'],
        isNot(storage.anchors['additional']![':baseline']),
      );
      await expectLater(
        ChangeSetSourceServiceClient(changes.requestChannel).snapshotUnstaged(),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (failure) => failure.code,
            'code',
            'invalid_host_invocation_context',
          ),
        ),
      );
      await expectLater(
        ChangeSetSourceServiceClient(
          changes.requestChannel,
        ).snapshotUncommitted(),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (failure) => failure.code,
            'code',
            'invalid_host_invocation_context',
          ),
        ),
      );
      await expectLater(
        ChangeSetSourceServiceClient(
          changes.requestChannel,
        ).snapshotTaskChanges(),
        throwsA(
          isA<PluginRemoteFailure>().having(
            (failure) => failure.code,
            'code',
            'invalid_host_invocation_context',
          ),
        ),
      );
      final unboundReview = ReviewApprovalHandlerServiceClient(
        approvals.requestChannel,
      );
      final unboundSelection = ReviewHunkSelection(
        relativePath: 'README.md',
        hunkIndex: 0,
        expectedRevision: 'not-authority',
      );
      for (final call in [
        unboundReview.approveHunk,
        unboundReview.unapproveHunk,
      ]) {
        await expectLater(
          call(unboundSelection),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (failure) => failure.code,
              'code',
              'invalid_host_invocation_context',
            ),
          ),
        );
      }
      for (final call in [
        unboundReview.approveAllUnstaged,
        unboundReview.unapproveAllStaged,
      ]) {
        await expectLater(
          call(ReviewLayerSelection(expectedRevision: 'not-authority')),
          throwsA(
            isA<PluginRemoteFailure>().having(
              (failure) => failure.code,
              'code',
              'invalid_host_invocation_context',
            ),
          ),
        );
      }
      Future<T> invoke<T>(
        String environmentId,
        ProviderBinding binding,
        Future<T> Function(AdeleRequestChannel) call,
      ) async {
        final processes = AuthorizedEnvironmentBufferedProcessServiceDispatcher(
          _DiffProcesses(provider, environmentId, roots.keys.toSet()),
        );
        final invocation = connection.openHostInvocation({
          authorizedEnvironmentBufferedProcessServiceId: processes,
        });
        try {
          return await call(
            connection.bindHostInvocation(
              channel: binding.requestChannel,
              invocation: invocation,
              validate: () {},
            ),
          );
        } finally {
          invocation.close();
          await processes.close();
        }
      }

      Future<ChangeSetSnapshot> snapshot(String id) => invoke(
        id,
        changes,
        (channel) => ChangeSetSourceServiceClient(channel).snapshotUnstaged(),
      );
      Future<UncommittedChangeSetSnapshot> uncommitted(String id) => invoke(
        id,
        changes,
        (channel) =>
            ChangeSetSourceServiceClient(channel).snapshotUncommitted(),
      );
      Future<TaskChangeSetSnapshot> taskChanges(String id) => invoke(
        id,
        changes,
        (channel) =>
            ChangeSetSourceServiceClient(channel).snapshotTaskChanges(),
      );

      final results = await Future.wait([
        snapshot('primary'),
        snapshot('additional'),
      ]);
      expect(
        results[0].files.single.hunks.single.lines.single.text,
        'primary content',
      );
      expect(
        results[1].files.single.hunks.single.lines.single.text,
        'additional content',
      );
      for (final name in roots.keys) {
        await _git(roots[name]!, ['add', 'same.txt']);
        final current = await provider.readFile(
          EnvironmentId(name),
          'same.txt',
        );
        await provider.replaceExistingTextFile(
          EnvironmentId(name),
          'same.txt',
          '$name working\n',
          current.revision,
        );
      }
      final layered = await Future.wait([
        uncommitted('primary'),
        uncommitted('additional'),
      ]);
      for (var i = 0; i < layered.length; i++) {
        final name = i == 0 ? 'primary' : 'additional';
        final result = layered[i];
        expect(result.staged.files.single.relativePath, 'same.txt');
        expect(result.staged.files.single.changeKind, 'added');
        expect(
          result.staged.files.single.hunks.single.lines.single.text,
          '$name content',
        );
        expect(result.unstaged.files.single.relativePath, 'same.txt');
        expect(result.unstaged.files.single.changeKind, 'modified');
        expect(
          result.unstaged.files.single.hunks.single.lines.map(
            (line) => '${line.kind}:${line.text}',
          ),
          ['deletion:$name content', 'addition:$name working'],
        );
        expect(result.conflicts, isEmpty);
      }
      // The retained establishment baseline remains valid but is not the live
      // staged comparison base once this worktree's HEAD has advanced.
      await _git(roots['additional']!, [
        '-c',
        'user.name=ADELE Test',
        '-c',
        'user.email=adele@example.invalid',
        'commit',
        '-m',
        'Advance live HEAD',
      ]);
      final advanced = await uncommitted('additional');
      expect(
        storage.reads,
        0,
        reason: 'Only Task requests may access storage.',
      );
      expect(advanced.staged.files, isEmpty);
      expect(
        advanced.unstaged.files.single.hunks.single.lines.last.text,
        'additional working',
      );
      final taskResults = await Future.wait([
        taskChanges('primary'),
        taskChanges('additional'),
      ]);
      expect(taskResults.first.committed.files, isEmpty);
      expect(taskResults.last.committed.files.single.relativePath, 'same.txt');
      expect(taskResults.last.committed.files.single.changeKind, 'added');
      expect(
        taskResults.last.committed.files.single.hunks.single.lines.single.text,
        'additional content',
      );
      expect(taskResults.last.uncommitted.staged.files, isEmpty);
      expect(
        taskResults
            .last
            .uncommitted
            .unstaged
            .files
            .single
            .hunks
            .single
            .lines
            .last
            .text,
        'additional working',
      );
      await _git(roots['additional']!, ['add', 'same.txt']);
      final indexed = await provider.readFile(
        EnvironmentId('additional'),
        'same.txt',
      );
      await provider.replaceExistingTextFile(
        EnvironmentId('additional'),
        'same.txt',
        'additional newest\n',
        indexed.revision,
      );
      final allLayers = await taskChanges('additional');
      expect(
        allLayers.committed.files.single.hunks.single.lines.single.text,
        'additional content',
      );
      expect(
        allLayers.uncommitted.staged.files.single.hunks.single.lines.map(
          (line) => line.text,
        ),
        ['additional content', 'additional working'],
      );
      expect(
        allLayers.uncommitted.unstaged.files.single.hunks.single.lines.map(
          (line) => line.text,
        ),
        ['additional working', 'additional newest'],
      );
      expect(allLayers.uncommitted.conflicts, isEmpty);
      final retainedAnchor = storage.anchors.remove('additional')!;
      await expectLater(
        taskChanges('additional'),
        throwsA(
          isA<ChangeSetFailure>().having(
            (failure) => failure.code,
            'code',
            'baseline_unavailable',
          ),
        ),
      );
      final readsWithoutAnchor = storage.reads;
      expect(
        (await snapshot('additional')).files.single.relativePath,
        'same.txt',
      );
      expect(
        (await uncommitted('additional')).staged.files.single.relativePath,
        'same.txt',
      );
      expect(storage.reads, readsWithoutAnchor);
      storage.anchors['additional'] = retainedAnchor;
      await expectLater(
        taskChanges('not-materialized'),
        throwsA(
          isA<ChangeSetFailure>().having(
            (failure) => failure.code,
            'code',
            'environment_process_failed',
          ),
        ),
      );
      await expectLater(
        uncommitted('not-materialized'),
        throwsA(
          isA<ChangeSetFailure>().having(
            (failure) => failure.code,
            'code',
            'environment_process_failed',
          ),
        ),
      );
      await expectLater(
        snapshot('not-materialized'),
        throwsA(
          isA<ChangeSetFailure>().having(
            (failure) => failure.code,
            'code',
            'environment_process_failed',
          ),
        ),
      );
      connection.revokeInfrastructureContext();
      await expectLater(
        taskChanges('additional'),
        throwsA(
          isA<ChangeSetFailure>().having(
            (failure) => failure.code,
            'code',
            'baseline_storage_failed',
          ),
        ),
      );
      expect(
        (await snapshot('additional')).files.single.relativePath,
        'same.txt',
      );
      // Review is independent of anchor SQL, even after its grant is revoked.
      final root = roots['additional']!;
      final readme = await provider.readFile(
        EnvironmentId('additional'),
        'README.md',
      );
      await provider.replaceExistingTextFile(
        EnvironmentId('additional'),
        'README.md',
        'AOT Git reviewed\n',
        readme.revision,
      );
      final workingBefore = await File('${root.path}/README.md').readAsBytes();
      final unrelatedBefore = await File('${root.path}/same.txt').readAsBytes();
      final headBefore = await _git(root, ['rev-parse', 'HEAD']);
      final refsBefore = await _git(root, ['show-ref']);
      final indexBefore = await _git(root, ['ls-files', '--stage', '-z']);
      final primaryBefore = await _git(roots['primary']!, [
        'ls-files',
        '--stage',
        '-z',
      ]);
      final readsBeforeReview = storage.reads;
      final target = (await snapshot(
        'additional',
      )).files.singleWhere((file) => file.relativePath == 'README.md');
      expect(target.hunks, hasLength(1));
      final selection = ReviewHunkSelection(
        relativePath: target.relativePath,
        hunkIndex: 0,
        expectedRevision: target.reviewRevision!,
      );
      await invoke(
        'additional',
        approvals,
        (channel) =>
            ReviewApprovalHandlerServiceClient(channel).approveHunk(selection),
      );
      expect(
        await _git(root, ['show', ':project-source/README.md']),
        'AOT Git reviewed',
      );
      await expectLater(
        invoke(
          'additional',
          approvals,
          (channel) => ReviewApprovalHandlerServiceClient(
            channel,
          ).approveHunk(selection),
        ),
        throwsA(
          isA<ReviewApprovalFailure>().having(
            (failure) => failure.code,
            'code',
            'stale_selection',
          ),
        ),
      );
      final approved = await uncommitted('additional');
      expect(approved.unstaged.files.map((file) => file.relativePath), [
        'same.txt',
      ]);
      final staged = approved.staged.files.singleWhere(
        (file) => file.relativePath == 'README.md',
      );
      expect(staged.reviewRevision, isNot(selection.expectedRevision));
      await invoke(
        'additional',
        approvals,
        (channel) => ReviewApprovalHandlerServiceClient(channel).unapproveHunk(
          ReviewHunkSelection(
            relativePath: staged.relativePath,
            hunkIndex: 0,
            expectedRevision: staged.reviewRevision!,
          ),
        ),
      );
      expect(await _git(root, ['ls-files', '--stage', '-z']), indexBefore);
      expect(await File('${root.path}/README.md').readAsBytes(), workingBefore);
      expect(
        await File('${root.path}/same.txt').readAsBytes(),
        unrelatedBefore,
      );
      expect(await _git(root, ['rev-parse', 'HEAD']), headBefore);
      expect(await _git(root, ['show-ref']), refsBefore);
      expect(
        await _git(roots['primary']!, ['ls-files', '--stage', '-z']),
        primaryBefore,
      );
      expect(storage.reads, readsBeforeReview);
      // Both new methods use the actual stock contextual dispatcher and ordinary
      // generated client, with no anchor-storage grant or Worktree association.
      final layer = await uncommitted('additional');
      expect(layer.unstaged.files.map((file) => file.relativePath), [
        'README.md',
        'same.txt',
      ]);
      final layerSelection = ReviewLayerSelection(
        expectedRevision: layer.unstaged.layerReviewRevision!,
      );
      await invoke(
        'additional',
        approvals,
        (channel) => ReviewApprovalHandlerServiceClient(
          channel,
        ).approveAllUnstaged(layerSelection),
      );
      String blob(String content) {
        final bytes = utf8.encode(content);
        return sha1.convert([
          ...utf8.encode('blob ${bytes.length}\u0000'),
          ...bytes,
        ]).toString();
      }

      expect(
        await _git(root, ['ls-files', '--stage', '-z']),
        indexBefore
            .replaceFirst(blob(readme.text), blob('AOT Git reviewed\n'))
            .replaceFirst(
              blob('additional working\n'),
              blob('additional newest\n'),
            ),
      );
      expect(
        await _git(root, ['show', ':project-source/README.md']),
        'AOT Git reviewed',
      );
      expect(
        await _git(root, ['show', ':project-source/same.txt']),
        'additional newest',
      );
      final allApproved = await uncommitted('additional');
      expect(allApproved.unstaged.files, isEmpty);
      expect(allApproved.unstaged.layerReviewRevision, isNull);
      expect(allApproved.staged.files.map((file) => file.relativePath), [
        'README.md',
        'same.txt',
      ]);
      final reverseSelection = ReviewLayerSelection(
        expectedRevision: allApproved.staged.layerReviewRevision!,
      );
      expect(
        reverseSelection.expectedRevision,
        isNot(layerSelection.expectedRevision),
      );
      await invoke(
        'additional',
        approvals,
        (channel) => ReviewApprovalHandlerServiceClient(
          channel,
        ).unapproveAllStaged(reverseSelection),
      );
      expect(
        await _git(root, ['ls-files', '--stage', '-z']),
        indexBefore.replaceFirst(
          blob('additional working\n'),
          blob('additional content\n'),
        ),
      );
      expect(await _git(root, ['diff', '--cached', '--exit-code']), isEmpty);
      final allUnapproved = await uncommitted('additional');
      expect(allUnapproved.staged.files, isEmpty);
      expect(allUnapproved.staged.layerReviewRevision, isNull);
      expect(allUnapproved.unstaged.files.map((file) => file.relativePath), [
        'README.md',
        'same.txt',
      ]);
      expect(await File('${root.path}/README.md').readAsBytes(), workingBefore);
      expect(
        await File('${root.path}/same.txt').readAsBytes(),
        unrelatedBefore,
      );
      expect(await _git(root, ['rev-parse', 'HEAD']), headBefore);
      expect(await _git(root, ['show-ref']), refsBefore);
      expect(
        await _git(roots['primary']!, ['ls-files', '--stage', '-z']),
        primaryBefore,
      );
      expect(storage.reads, readsBeforeReview);
      await activation.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip: !Platform.isLinux ? 'Portable Git inspection requires Linux.' : false,
  );

  test(
    'AOT foreground paused transport retains output across normal exit',
    () async {
      final fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final registry = CapabilityRegistry();
      final providerId = ProviderId(gitWorktreeEnvironmentProviderId);
      final activation = await _register(
        await host.startPlugin(
          pluginId: gitPluginId,
          artifactUri: pluginArtifact.uri,
        ),
        registry,
      );
      final provider = GeneratedEnvironmentProvider(
        providerId: providerId,
        service: EnvironmentProviderServiceClient(
          registry
              .resolve(environmentProviderCapability, providerId: providerId)
              .requestChannel,
        ),
      );
      final project = Project(
        id: ProjectId('paused-project'),
        sourceLocation: fixture.projectSourceA.uri,
      );
      final task = Task(
        id: TaskId('paused-task'),
        projectId: project.id,
        title: 'Paused output',
      );
      final environment = Environment(
        id: EnvironmentId('paused-environment'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: providerId,
        providerState: null,
      );
      await provider.establish(
        LocalEnvironment(project: project, task: task, value: environment),
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final connection = server.first;
      final paused = Completer<void>();
      final done = Completer<void>();
      final events = <EnvironmentProcessEvent>[];
      final failures = <Object>[];
      late StreamSubscription<EnvironmentProcessEvent> subscription;
      subscription = provider
          .runForegroundProcess(
            environment.id,
            EnvironmentForegroundProcessRequest(
              program: '/bin/bash',
              arguments: [
                '-c',
                'exec 3<>/dev/tcp/127.0.0.1/${server.port}; '
                    r'''printf '%s' "$1"; printf '%s' "$2" >&2; exit 23''',
                'probe',
                'O' * 4096,
                'E' * 4096,
              ],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .listen(
            (event) {
              events.add(event);
              if (!paused.isCompleted) {
                subscription.pause();
                paused.complete();
              }
            },
            onError: failures.add,
            onDone: done.complete,
          );
      addTearDown(subscription.cancel);
      final socket = await connection.timeout(const Duration(seconds: 5));
      addTearDown(socket.destroy);
      final exited = socket.drain<void>();
      await paused.future.timeout(const Duration(seconds: 5));
      await exited.timeout(const Duration(seconds: 5));
      expect(done.isCompleted, isFalse);
      expect(events, hasLength(1));
      expect(
        (await provider.readFile(environment.id, 'README.md')).text,
        'AOT Git fixture A\n',
      );
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 5));
      expect(failures, isEmpty);
      expect(_stdoutText(events), 'O' * 4096);
      expect(
        events
            .where(
              (event) =>
                  event.output?.stream == EnvironmentProcessOutputStream.stderr,
            )
            .map((event) => event.output!.text)
            .join(),
        'E' * 4096,
      );
      expect(events.last.completed!.exitCode, 23);
      expect(events.last.completed!.stdoutTruncated, isFalse);
      expect(events.last.completed!.stderrTruncated, isFalse);
      await activation.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'AOT generations ignore inherited Git routing/discovery and restore state',
    () async {
      final ({
        Directory container,
        Directory projectSourceA,
        Directory sourceA,
        Directory sourceB,
      })
      fixture = await _createRepository();
      addTearDown(() => fixture.container.delete(recursive: true));
      final shim = await _createGitRepairShim(fixture.container, 'unavailable');
      final String childPath =
          'relative-bin:${shim.directory.path}:'
          '${Platform.environment['PATH'] ?? '/usr/bin:/bin'}';
      final String gitDirVariable = Platform.isWindows ? 'git_dir' : 'GIT_DIR';
      final String ceilingVariable = Platform.isWindows
          ? 'Git_Ceiling_Directories'
          : 'GIT_CEILING_DIRECTORIES';
      final PluginBackendHost host = await PluginBackendHost.start(
        dartaotruntimeExecutable: dartaotruntime,
        hostArtifactPath: hostArtifact.path,
        environment: <String, String>{
          gitDirVariable:
              '${fixture.sourceB.path}${Platform.pathSeparator}.git',
          'GIT_WORK_TREE': fixture.sourceB.path,
          ceilingVariable: fixture.sourceA.path,
          'GIT_DISCOVERY_ACROSS_FILESYSTEM': 'false',
          'ADELE_PROCESS_SECRET_SHOULD_NOT_LEAK': 'sentinel',
          'OPENAI_API_KEY': 'sentinel',
          'PATH': childPath,
        },
      );
      addTearDown(() async {
        if (!host.isClosed) await host.close(graceful: false);
      });
      final CapabilityRegistry registry = CapabilityRegistry();
      final ProviderId providerId = ProviderId(
        gitWorktreeEnvironmentProviderId,
      );
      final Project project = Project(
        id: ProjectId('project-aot'),
        sourceLocation: fixture.projectSourceA.uri,
      );
      final Task task = Task(
        id: TaskId('task-aot'),
        projectId: project.id,
        title: 'AOT Generation Proof',
      );
      final Environment provisional = Environment(
        id: EnvironmentId('environment-\taot'),
        taskId: task.id,
        role: EnvironmentRole.primary,
        providerId: providerId,
        providerState: null,
      );

      final PluginBackendConnection generationA = await host.startPlugin(
        pluginId: gitPluginId,
        artifactUri: pluginArtifact.uri,
      );
      final PluginCapabilityActivation activationA = await _register(
        generationA,
        registry,
      );
      final ProviderBinding bindingA = registry.resolve(
        environmentProviderCapability,
        providerId: providerId,
      );
      final GeneratedEnvironmentProvider providerA =
          GeneratedEnvironmentProvider(
            providerId: providerId,
            service: EnvironmentProviderServiceClient(bindingA.requestChannel),
          );
      final EnvironmentProviderResult established = await providerA.establish(
        LocalEnvironment(project: project, task: task, value: provisional),
      );
      final String worktreePath = <String>[
        fixture.projectSourceA.path,
        ...(established.providerState['worktreeRelativePath']! as String).split(
          '/',
        ),
      ].join(Platform.pathSeparator);
      expect(
        established.providerState.keys,
        unorderedEquals(<String>[
          'schemaVersion',
          'environmentId',
          'sourceRelativePath',
          'worktreeRelativePath',
          'branch',
        ]),
      );
      expect(established.providerState['schemaVersion'], allOf(isA<int>(), 2));
      expect(established.providerState['environmentId'], 'environment-\taot');
      expect(established.providerState['sourceRelativePath'], 'project-source');
      expect(
        established.providerState['worktreeRelativePath'],
        matches(r'^\.adele/worktrees/[a-z0-9-]+$'),
      );
      final Environment durable = Environment(
        id: provisional.id,
        taskId: provisional.taskId,
        role: provisional.role,
        providerId: provisional.providerId,
        providerState: established.providerState,
      );
      expect(
        established.initialState!.inserts.single.parameters[':baseline'],
        await _git(fixture.sourceA, <String>['rev-parse', 'HEAD']),
      );
      expect(
        established.initialState!.inserts.single.parameters[':baseline'],
        isNot(await _git(fixture.sourceB, <String>['rev-parse', 'HEAD'])),
      );
      final EnvironmentTextFile firstRead = await providerA.readFile(
        durable.id,
        'README.md',
      );
      expect(firstRead.text, 'AOT Git fixture A\n');
      final EnvironmentTextFileCreation creation = await providerA
          .createTextFile(
            durable.id,
            'generated-create-delete.txt',
            'generated AOT content\n',
          );
      final EnvironmentTextFile createdRead = await providerA.readFile(
        durable.id,
        'generated-create-delete.txt',
      );
      expect(createdRead.text, 'generated AOT content\n');
      expect(createdRead.revision, creation.revision);
      await providerA.deleteExistingTextFile(
        durable.id,
        'generated-create-delete.txt',
        createdRead.revision,
      );
      await expectLater(
        providerA.readFile(durable.id, 'generated-create-delete.txt'),
        throwsA(_failureWithCode('not_found')),
      );
      final List<EnvironmentProcessEvent> processEvents = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>[
                'rev-parse',
                '--show-toplevel',
                '--show-prefix',
              ],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      final List<String> processLines = _stdoutText(
        processEvents,
      ).trim().split('\n');
      expect(processLines, hasLength(2));
      expect(processLines.first, worktreePath);
      expect(processLines.last, 'project-source/');
      expect(processEvents.last.kind, EnvironmentProcessEventKind.completed);
      expect(processEvents.last.completed!.exitCode, 0);
      expect(
        (await providerA.readFile(durable.id, 'README.md')).text,
        firstRead.text,
      );
      final List<EnvironmentProcessEvent> environmentEvents = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'env',
              arguments: const <String>[],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      final List<String> childEnvironment = _stdoutText(
        environmentEvents,
      ).split('\n');
      expect(
        childEnvironment,
        isNot(contains('ADELE_PROCESS_SECRET_SHOULD_NOT_LEAK=sentinel')),
      );
      expect(childEnvironment, isNot(contains('OPENAI_API_KEY=sentinel')));
      expect(
        childEnvironment.any(
          (String variable) =>
              variable.startsWith('PATH=') && variable.length > 'PATH='.length,
        ),
        isTrue,
      );
      expect(childEnvironment, contains('PATH=$childPath'));
      expect(
        childEnvironment,
        contains(
          'PWD=$worktreePath'
          '${Platform.pathSeparator}project-source',
        ),
      );
      final List<EnvironmentProcessEvent> cleanStatus = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>['status', '--short'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      expect(_stdoutText(cleanStatus), isEmpty);
      expect(cleanStatus.last.completed!.exitCode, 0);
      final List<EnvironmentProcessEvent> relativePathProcess = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'adele-relative-path-probe',
              arguments: const <String>[],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      expect(
        _stdoutText(relativePathProcess),
        'relative-path:$worktreePath'
        '${Platform.pathSeparator}project-source',
      );
      expect(relativePathProcess.last.completed!.exitCode, 0);
      final continuousOutput = await providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: '/usr/bin/head',
              arguments: ['-c', '2097152', '/dev/zero'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      expect(_stdoutText(continuousOutput), '\x00' * 2097152);
      expect(continuousOutput.last.completed!.exitCode, 0);
      expect(continuousOutput.last.completed!.stdoutTruncated, isFalse);
      expect(
        continuousOutput
            .where((event) => event.output != null)
            .every(
              (event) =>
                  event.output!.text.length <= environmentProcessTextLimit,
            ),
        isTrue,
      );
      final Stream<EnvironmentProcessEvent> deferredGenerationA = providerA
          .runForegroundProcess(
            durable.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>['status', '--short'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          );
      final EnvironmentTextFileReplacement replacement = await providerA
          .replaceExistingTextFile(
            durable.id,
            'README.md',
            'AOT conditional replacement\n',
            firstRead.revision,
          );
      final EnvironmentTextFile replacedRead = await providerA.readFile(
        durable.id,
        'README.md',
      );
      expect(replacedRead.text, 'AOT conditional replacement\n');
      expect(replacedRead.revision, replacement.revision);
      expect(replacedRead.revision, isNot(firstRead.revision));
      await expectLater(
        providerA.replaceExistingTextFile(
          durable.id,
          'README.md',
          'stale replacement\n',
          firstRead.revision,
        ),
        throwsA(_failureWithCode('revision_conflict')),
      );

      await activationA.close();
      final PluginBackendConnection generationB = await host.startPlugin(
        pluginId: gitPluginId,
        artifactUri: pluginArtifact.uri,
      );
      final PluginCapabilityActivation activationB = await _register(
        generationB,
        registry,
      );
      expect(
        () => bindingA.requestChannel,
        throwsA(
          isA<ProviderUnavailable>()
              .having(
                (ProviderUnavailable failure) => failure.stale,
                'stale',
                isTrue,
              )
              .having(
                (ProviderUnavailable failure) => failure.providerId,
                'providerId',
                providerId,
              ),
        ),
      );
      await expectLater(
        providerA.readFile(durable.id, 'README.md'),
        throwsA(isA<PluginConnectionClosed>()),
      );
      await expectLater(
        deferredGenerationA,
        emitsError(isA<PluginConnectionClosed>()),
      );

      expect(durable.providerId, providerId);
      expect(durable.providerState, established.providerState);
      final ProviderBinding bindingB = registry.resolve(
        environmentProviderCapability,
        providerId: providerId,
      );
      final GeneratedEnvironmentProvider providerB =
          GeneratedEnvironmentProvider(
            providerId: providerId,
            service: EnvironmentProviderServiceClient(bindingB.requestChannel),
          );
      final EnvironmentProviderResult restored = await providerB.restore(
        LocalEnvironment(project: project, task: task, value: durable),
      );
      expect(restored.initialState, isNull);
      final Environment refreshed = Environment(
        id: durable.id,
        taskId: durable.taskId,
        role: durable.role,
        providerId: durable.providerId,
        providerState: restored.providerState,
      );
      expect(
        (await providerB.readFile(refreshed.id, 'README.md')).text,
        'AOT conditional replacement\n',
      );
      expect(refreshed.providerState, durable.providerState);
      final List<EnvironmentProcessEvent> freshProcess = await providerB
          .runForegroundProcess(
            refreshed.id,
            EnvironmentForegroundProcessRequest(
              program: 'git',
              arguments: const <String>['status', '--short'],
              relativeWorkingDirectory: '',
              timeoutSeconds: 10,
            ),
          )
          .toList();
      expect(freshProcess.last.completed!.exitCode, 0);
      expect(_stdoutText(freshProcess), contains('M README.md'));
      expect(
        await shim.log.exists(),
        isFalse,
        reason:
            'A healthy restore must not require Git worktree repair support.',
      );

      await activationB.close();
      await host.close();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  for (final String mode in <String>[
    'unavailable',
    'failure',
    'no-op',
    'corrupt-after-repair',
  ]) {
    test(
      'AOT relocation rejects repair $mode without publishing an Environment',
      () async {
        final fixture = await _createRepository();
        addTearDown(() => fixture.container.delete(recursive: true));
        final shim = await _createGitRepairShim(fixture.container, mode);
        final PluginBackendHost host = await PluginBackendHost.start(
          dartaotruntimeExecutable: dartaotruntime,
          hostArtifactPath: hostArtifact.path,
          environment: <String, String>{
            'PATH':
                '${shim.directory.path}:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
          },
        );
        addTearDown(() async {
          if (!host.isClosed) await host.close(graceful: false);
        });
        final CapabilityRegistry registry = CapabilityRegistry();
        final ProviderId providerId = ProviderId(
          gitWorktreeEnvironmentProviderId,
        );
        final Project project = Project(
          id: ProjectId('project-repair'),
          sourceLocation: fixture.projectSourceA.uri,
        );
        final Task task = Task(
          id: TaskId('task-repair'),
          projectId: project.id,
          title: 'Repair failure',
        );
        final Environment provisional = Environment(
          id: EnvironmentId('environment-repair'),
          taskId: task.id,
          role: EnvironmentRole.primary,
          providerId: providerId,
          providerState: null,
        );
        final PluginCapabilityActivation activationA = await _register(
          await host.startPlugin(
            pluginId: gitPluginId,
            artifactUri: pluginArtifact.uri,
          ),
          registry,
        );
        final GeneratedEnvironmentProvider providerA =
            GeneratedEnvironmentProvider(
              providerId: providerId,
              service: EnvironmentProviderServiceClient(
                registry
                    .resolve(
                      environmentProviderCapability,
                      providerId: providerId,
                    )
                    .requestChannel,
              ),
            );
        final EnvironmentProviderResult established = await providerA.establish(
          LocalEnvironment(project: project, task: task, value: provisional),
        );
        final Environment durable = Environment(
          id: provisional.id,
          taskId: task.id,
          role: provisional.role,
          providerId: providerId,
          providerState: established.providerState,
        );
        final String relative =
            established.providerState['worktreeRelativePath']! as String;
        final String oldRoot = '${fixture.projectSourceA.path}/$relative';
        await providerA.createTextFile(
          durable.id,
          'retained.txt',
          'preserved across failed restore',
        );
        await activationA.close();
        final Directory movedRepository = await fixture.sourceA.rename(
          '${fixture.container.path}/moved-source',
        );
        final Directory movedSource = Directory(
          '${movedRepository.path}/project-source',
        );
        final String expectedRoot = '${movedSource.path}/$relative';
        expect(await Directory(oldRoot).exists(), isFalse);
        expect(await Directory(expectedRoot).exists(), isTrue);
        final String inventory = await _git(movedRepository, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]);
        expect(inventory.split('\u0000'), contains('worktree $oldRoot'));
        final PluginCapabilityActivation activationB = await _register(
          await host.startPlugin(
            pluginId: gitPluginId,
            artifactUri: pluginArtifact.uri,
          ),
          registry,
        );
        final GeneratedEnvironmentProvider providerB =
            GeneratedEnvironmentProvider(
              providerId: providerId,
              service: EnvironmentProviderServiceClient(
                registry
                    .resolve(
                      environmentProviderCapability,
                      providerId: providerId,
                    )
                    .requestChannel,
              ),
            );
        final String code = switch (mode) {
          'unavailable' || 'failure' => 'restore_worktree_repair_failed',
          'no-op' => 'restore_worktree_mismatch',
          _ => 'restore_worktree_invalid',
        };
        await expectLater(
          providerB.restore(
            LocalEnvironment(
              project: Project(id: project.id, sourceLocation: movedSource.uri),
              task: task,
              value: durable,
            ),
          ),
          throwsA(
            isA<EnvironmentFailure>()
                .having(
                  (EnvironmentFailure failure) => failure.code,
                  'code',
                  code,
                )
                .having(
                  (EnvironmentFailure failure) => failure.message,
                  'message',
                  isNotEmpty,
                )
                .having(
                  (EnvironmentFailure failure) =>
                      failure.details.toString().length,
                  'bounded diagnostics',
                  lessThanOrEqualTo(2000),
                )
                .having(
                  (EnvironmentFailure failure) =>
                      mode == 'unavailable' || mode == 'failure'
                      ? failure.details['gitError']
                      : '',
                  'repair diagnostic',
                  mode == 'unavailable'
                      ? contains('repair unsupported')
                      : mode == 'failure'
                      ? allOf(
                          startsWith('repair denied:'),
                          hasLength(lessThanOrEqualTo(1000)),
                        )
                      : isEmpty,
                ),
          ),
        );
        await expectLater(
          providerB.readFile(durable.id, 'README.md'),
          throwsA(_failureWithCode('environment_not_live')),
        );
        final List<String> repairArguments = await shim.log.readAsLines();
        expect(
          repairArguments.where((String argument) => argument == 'repair'),
          hasLength(1),
        );
        expect(repairArguments, contains(expectedRoot));
        expect(repairArguments, isNot(contains(oldRoot)));
        expect(
          await File(
            '$expectedRoot/project-source/retained.txt',
          ).readAsString(),
          'preserved across failed restore',
        );
        expect(durable.providerState, established.providerState);
        final String after = await _git(movedRepository, <String>[
          'worktree',
          'list',
          '--porcelain',
          '-z',
        ]);
        if (mode == 'corrupt-after-repair') {
          expect(after.split('\u0000'), contains('worktree $expectedRoot'));
          expect(after.split('\u0000'), isNot(contains('worktree $oldRoot')));
        } else {
          expect(after, inventory);
        }
        await activationB.close();
        await host.close();
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: Platform.isWindows
          ? 'The Git PATH shim uses a POSIX shell.'
          : false,
    );
  }
}

String _stdoutText(List<EnvironmentProcessEvent> events) => events
    .where(
      (EnvironmentProcessEvent event) =>
          event.output?.stream == EnvironmentProcessOutputStream.stdout,
    )
    .map((EnvironmentProcessEvent event) => event.output!.text)
    .join();

Matcher _failureWithCode(String code) => isA<EnvironmentFailure>().having(
  (EnvironmentFailure failure) => failure.code,
  'code',
  code,
);

Future<({Directory directory, File log})> _createGitRepairShim(
  Directory container,
  String mode,
) async {
  final ProcessResult lookup = await Process.run('/bin/sh', <String>[
    '-c',
    'command -v git',
  ]);
  if (lookup.exitCode != 0) throw StateError(lookup.stderr.toString());
  final String git = lookup.stdout.toString().trim();
  final Directory directory = Directory('${container.path}/git-shim')
    ..createSync();
  final File log = File('${container.path}/repair.log');
  final File wrapper = File('${directory.path}/git');
  final String repair = switch (mode) {
    'unavailable' =>
      "printf '%s\\n' 'repair unsupported by this Git' >&2\nexit 129",
    'failure' => "printf '%s\\n' 'repair denied:${'x' * 16000}' >&2\nexit 1",
    'no-op' => 'exit 0',
    'corrupt-after-repair' =>
      '${_shellQuote(git)} "\$@" || exit \$?\nprintf broken > "\$5/.git"\nexit 0',
    _ => throw ArgumentError.value(mode),
  };
  await wrapper.writeAsString('''#!/bin/sh
if [ "\$1" = "-C" ] && [ "\$3" = "worktree" ] && [ "\$4" = "repair" ]; then
  printf '%s\\n' "\$@" >> ${_shellQuote(log.path)}
  $repair
fi
exec ${_shellQuote(git)} "\$@"
''');
  final ProcessResult chmod = await Process.run('chmod', <String>[
    '755',
    wrapper.path,
  ]);
  if (chmod.exitCode != 0) throw StateError(chmod.stderr.toString());
  return (directory: directory, log: log);
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

final class _DiffProcesses
    implements AuthorizedEnvironmentBufferedProcessService {
  const _DiffProcesses(this.provider, this.environmentId, this.liveIds);
  final GeneratedEnvironmentProvider provider;
  final String environmentId;
  final Set<String> liveIds;
  @override
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async {
    if (!liveIds.contains(environmentId)) {
      throw const EnvironmentFailure(
        code: 'environment_not_live',
        message: 'The captured Environment is not live.',
        details: {},
      );
    }
    return AuthorizedEnvironmentIdentity(
      sessionId: 'session-$environmentId',
      environmentId: environmentId,
    );
  }

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) => provider.runBufferedProcess(EnvironmentId(environmentId), request);
}

// Transport fixture only. Atomic SQL and durable reopen are covered by app tests.
final class _DiffStorage implements ProjectStorageService {
  final anchors = <String, Map<String, Object?>>{};
  late void Function() validate;
  int reads = 0;
  @override
  Future<void> ensureSchemaForSession(
    String sessionId,
    List<String> migrations,
    ProjectStorageAccessMode accessMode,
  ) async {
    validate();
    expect(migrations, [gitTaskAnchorSchema]);
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
  }

  @override
  Future<List<RelationalRow>> queryForSession(
    String sessionId,
    String sql,
    Map<String, Object?> parameters,
    ProjectStorageAccessMode accessMode,
  ) async {
    validate();
    reads++;
    expect(parameters, {':session': sessionId});
    expect(sql, contains('LEFT JOIN adele_git_task_anchors'));
    expect(accessMode, ProjectStorageAccessMode.durableOrTemporary);
    final environmentId = sessionId.substring('session-'.length);
    final anchor = anchors[environmentId];
    return [
      RelationalRow(
        values: {
          'session_id': sessionId,
          'session_task_id': 'diff-task',
          'selected_environment_id': environmentId,
          'environment_id': environmentId,
          'environment_task_id': 'diff-task',
          'anchor_environment_id': anchor?[':environment'],
          'baseline_commit': anchor?[':baseline'],
          'expected_branch_ref': anchor?[':branch'],
        },
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Snapshots must not write or reenroll anchors.');
}

Future<PluginCapabilityActivation> _register(
  PluginBackendConnection connection,
  CapabilityRegistry registry,
) => PluginCapabilityActivation.register(
  connection: connection,
  registry: registry,
  exposures: <PluginCapabilityExposure>[
    PluginCapabilityExposure(
      provider: ProviderDescriptor(
        id: ProviderId(gitWorktreeEnvironmentProviderId),
        capability: environmentProviderCapability,
        pluginId: connection.pluginId,
        displayName: 'Git Worktree Environment',
        serviceId: environmentProviderServiceId,
      ),
      configurationContext: connection.defaultConfigurationContext,
    ),
  ],
);

Future<
  ({
    Directory container,
    Directory projectSourceA,
    Directory sourceA,
    Directory sourceB,
  })
>
_createRepository() async {
  final Directory container = await Directory.systemTemp.createTemp(
    'adele-git-environment-aot-',
  );
  final Directory sourceA = Directory('${container.path}/source-a');
  final Directory sourceB = Directory('${container.path}/source-b');
  await _initializeRepository(sourceA, 'AOT Git fixture A\n');
  await _initializeRepository(sourceB, 'AOT Git fixture B\n');
  final Directory projectSourceA = Directory(
    '${sourceA.path}${Platform.pathSeparator}project-source',
  );
  await projectSourceA.create();
  await File(
    '${projectSourceA.path}${Platform.pathSeparator}README.md',
  ).writeAsString('AOT Git fixture A\n');
  final Directory relativeBin = Directory(
    '${projectSourceA.path}${Platform.pathSeparator}relative-bin',
  );
  await relativeBin.create();
  final File relativePathProbe = File(
    '${relativeBin.path}${Platform.pathSeparator}adele-relative-path-probe',
  );
  await relativePathProbe.writeAsString(
    '#!/bin/sh\nprintf "relative-path:%s" "\$PWD"\n',
  );
  final ProcessResult chmod = await Process.run('chmod', <String>[
    '755',
    relativePathProbe.path,
  ]);
  if (chmod.exitCode != 0) throw StateError(chmod.stderr.toString());
  await _git(sourceA, <String>['add', '.']);
  await _git(sourceA, <String>['commit', '-m', 'Add nested Project source']);
  return (
    container: container,
    projectSourceA: projectSourceA,
    sourceA: sourceA,
    sourceB: sourceB,
  );
}

Future<void> _initializeRepository(Directory source, String marker) async {
  await source.create();
  await _git(source, <String>['init', '--object-format=sha1']);
  await _git(source, <String>['config', 'user.name', 'ADELE Test']);
  await _git(source, <String>['config', 'user.email', 'adele@example.invalid']);
  await File('${source.path}/README.md').writeAsString(marker);
  await _git(source, <String>['add', '.']);
  await _git(source, <String>['commit', '-m', 'Initial fixture']);
}

Future<String> _git(Directory source, List<String> arguments) async {
  final ProcessResult result = await Process.run('git', <String>[
    '-C',
    source.path,
    ...arguments,
  ]);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout.toString().trim();
}

Future<void> _compile(
  String dart,
  String entrypoint,
  String output,
  String workingDirectory,
) async {
  final ProcessResult result = await Process.run(dart, <String>[
    'compile',
    'aot-snapshot',
    entrypoint,
    '-o',
    output,
  ], workingDirectory: workingDirectory);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
}
