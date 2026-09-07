import 'dart:async';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_product/adele_product.dart';
import 'package:test/test.dart';

void main() {
  final ProviderId providerId = ProviderId('dev.adele.environment.fixture');
  final Project hostProject = Project(
    id: ProjectId('project-host'),
    sourceLocation: Uri.parse('file:///tmp/source'),
  );
  final Task hostTask = Task(
    id: TaskId('task-host'),
    projectId: hostProject.id,
    title: 'Host task',
  );
  final Environment hostEnvironment = Environment(
    id: EnvironmentId('environment-host'),
    taskId: hostTask.id,
    role: EnvironmentRole.primary,
    providerId: providerId,
    providerState: null,
  );

  test('local Environment provides convenient relationship navigation', () {
    final LocalEnvironment local = LocalEnvironment(
      project: hostProject,
      task: hostTask,
      value: hostEnvironment,
    );

    expect(local.task.project.sourceLocation, Uri.parse('file:///tmp/source'));
    expect(local.task.id, hostTask.id);
    expect(local.id, hostEnvironment.id);
  });

  test('local Environment rejects contradictory product relationships', () {
    final Project anotherProject = Project(
      id: ProjectId('project-other'),
      sourceLocation: Uri.parse('file:///tmp/other'),
    );
    expect(
      () => LocalEnvironment(
        project: anotherProject,
        task: hostTask,
        value: hostEnvironment,
      ),
      throwsArgumentError,
    );
    expect(
      () => LocalEnvironment(
        project: hostProject,
        task: hostTask,
        value: Environment(
          id: EnvironmentId('environment-other'),
          taskId: TaskId('task-other'),
          role: EnvironmentRole.primary,
          providerId: providerId,
          providerState: null,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('adapters reconstruct component-local canonical values', () async {
    final _CapturingProvider backend = _CapturingProvider(providerId);
    final GeneratedEnvironmentProvider host = GeneratedEnvironmentProvider(
      providerId: providerId,
      service: EnvironmentProviderServiceAdapter(backend),
    );
    final LocalEnvironment hostLocal = LocalEnvironment(
      project: hostProject,
      task: hostTask,
      value: hostEnvironment,
    );

    final EnvironmentProviderResult result = await host.establish(hostLocal);
    final LocalEnvironment backendLocal = backend.established!;

    expect(result.providerState, <String, Object?>{'fixture': true});
    expect(backendLocal.value, isNot(same(hostEnvironment)));
    expect(backendLocal.task.value, isNot(same(hostTask)));
    expect(backendLocal.task.project, isNot(same(hostProject)));
    expect(backendLocal.task.project.id, hostProject.id);
    expect(
      backendLocal.task.project.sourceLocation,
      hostProject.sourceLocation,
    );
    expect(backendLocal.task.value.projectId, backendLocal.task.project.id);
    expect(backendLocal.value.taskId, backendLocal.task.id);
    expect(backendLocal.providerState, isNull);
  });

  test(
    'restore carries an immutable core-held provider-state snapshot',
    () async {
      final _CapturingProvider backend = _CapturingProvider(providerId);
      final GeneratedEnvironmentProvider host = GeneratedEnvironmentProvider(
        providerId: providerId,
        service: EnvironmentProviderServiceAdapter(backend),
      );
      final Environment finalized = Environment(
        id: hostEnvironment.id,
        taskId: hostEnvironment.taskId,
        role: hostEnvironment.role,
        providerId: providerId,
        providerState: <String, Object?>{'worktree': '/tmp/worktree'},
      );

      await host.restore(
        LocalEnvironment(
          project: hostProject,
          task: hostTask,
          value: finalized,
        ),
      );

      expect(backend.restored!.providerState, <String, Object?>{
        'worktree': '/tmp/worktree',
      });
      expect(
        () => backend.restored!.providerState!['worktree'] = '/tmp/other',
        throwsUnsupportedError,
      );
    },
  );

  test('generated client encodes Environment filesystem operations', () async {
    final _Channel channel = _Channel(<String, Object?>{
      'relativePath': 'lib/main.dart',
      'text': 'void main() {}',
      'sizeBytes': 14,
      'revision': 'opaque-read-revision',
    });

    final EnvironmentTextFile file = await EnvironmentProviderServiceClient(
      channel,
    ).readFile('environment-host', 'lib/main.dart');

    expect(channel.method, environmentProviderServiceReadFileId);
    expect(channel.payload, <String, Object?>{
      'environmentId': 'environment-host',
      'relativePath': 'lib/main.dart',
    });
    expect(file.text, 'void main() {}');
    expect(file.revision, 'opaque-read-revision');
  });

  test('generated client carries conditional replacement revisions', () async {
    final _Channel channel = _Channel(<String, Object?>{
      'revision': 'opaque-replacement-revision',
    });

    final EnvironmentTextFileReplacement replacement =
        await EnvironmentProviderServiceClient(channel).replaceExistingTextFile(
          'environment-host',
          'lib/main.dart',
          'void main() { print("updated"); }',
          'opaque-expected-revision',
        );

    expect(channel.method, environmentProviderServiceReplaceExistingTextFileId);
    expect(channel.payload, <String, Object?>{
      'environmentId': 'environment-host',
      'relativePath': 'lib/main.dart',
      'replacementText': 'void main() { print("updated"); }',
      'expectedRevision': 'opaque-expected-revision',
    });
    expect(replacement.revision, 'opaque-replacement-revision');
  });

  test('foreground process request validates and snapshots argv', () {
    final List<String> arguments = <String>['status', '--short'];
    final EnvironmentForegroundProcessRequest request =
        EnvironmentForegroundProcessRequest(
          program: 'git',
          arguments: arguments,
          relativeWorkingDirectory: './packages//environment',
          timeoutSeconds: 120,
        );
    arguments.add('--branch');

    expect(request.arguments, <String>['status', '--short']);
    expect(() => request.arguments.add('late'), throwsUnsupportedError);
    expect(
      () => EnvironmentForegroundProcessRequest(
        program: '',
        arguments: const <String>[],
        relativeWorkingDirectory: '',
        timeoutSeconds: 1,
      ),
      throwsFormatException,
    );
    for (final ({String program, List<String> arguments}) malformed
        in <({String program, List<String> arguments})>[
          (program: 'bad\u0000program', arguments: const <String>[]),
          (program: 'git', arguments: const <String>['bad\u0000argument']),
          (program: String.fromCharCode(0xd800), arguments: const <String>[]),
        ]) {
      expect(
        () => EnvironmentForegroundProcessRequest(
          program: malformed.program,
          arguments: malformed.arguments,
          relativeWorkingDirectory: '',
          timeoutSeconds: 1,
        ),
        throwsFormatException,
      );
    }
    for (final int timeoutSeconds in <int>[0, 601]) {
      expect(
        () => EnvironmentForegroundProcessRequest(
          program: 'git',
          arguments: const <String>[],
          relativeWorkingDirectory: '',
          timeoutSeconds: timeoutSeconds,
        ),
        throwsFormatException,
      );
    }
  });

  test('process event payloads enforce output and completion invariants', () {
    final EnvironmentProcessEvent output = EnvironmentProcessEvent(
      kind: EnvironmentProcessEventKind.output,
      output: EnvironmentProcessOutput(
        stream: EnvironmentProcessOutputStream.stderr,
        text: 'diagnostic',
      ),
      completed: null,
    );
    final EnvironmentProcessEvent exited = EnvironmentProcessEvent(
      kind: EnvironmentProcessEventKind.completed,
      output: null,
      completed: EnvironmentProcessCompleted(
        termination: EnvironmentProcessTermination.exited,
        exitCode: 3,
        stdoutTruncated: true,
        stderrTruncated: false,
      ),
    );
    final EnvironmentProcessEvent timedOut = EnvironmentProcessEvent(
      kind: EnvironmentProcessEventKind.completed,
      output: null,
      completed: EnvironmentProcessCompleted(
        termination: EnvironmentProcessTermination.timedOut,
        exitCode: null,
        stdoutTruncated: false,
        stderrTruncated: false,
      ),
    );

    expect(output.output!.stream, EnvironmentProcessOutputStream.stderr);
    expect(
      EnvironmentProcessOutput(
        stream: EnvironmentProcessOutputStream.stdout,
        text: '\u0000',
      ).text,
      '\u0000',
    );
    expect(exited.completed!.exitCode, 3);
    expect(timedOut.completed!.exitCode, isNull);
    expect(
      () => EnvironmentProcessOutput(
        stream: EnvironmentProcessOutputStream.stdout,
        text: '',
      ),
      throwsFormatException,
    );
    expect(
      () => EnvironmentProcessCompleted(
        termination: EnvironmentProcessTermination.exited,
        exitCode: null,
        stdoutTruncated: false,
        stderrTruncated: false,
      ),
      throwsFormatException,
    );
    expect(
      () => EnvironmentProcessCompleted(
        termination: EnvironmentProcessTermination.timedOut,
        exitCode: -15,
        stdoutTruncated: false,
        stderrTruncated: false,
      ),
      throwsFormatException,
    );
    expect(
      () => EnvironmentProcessEvent(
        kind: EnvironmentProcessEventKind.output,
        output: null,
        completed: timedOut.completed,
      ),
      throwsFormatException,
    );
  });

  test(
    'generated client streams typed foreground process events lazily',
    () async {
      final _ProcessStreamChannel channel = _ProcessStreamChannel();
      final EnvironmentProviderServiceClient client =
          EnvironmentProviderServiceClient(channel);
      final EnvironmentForegroundProcessRequest request =
          EnvironmentForegroundProcessRequest(
            program: 'git',
            arguments: const <String>['status', '--short'],
            relativeWorkingDirectory: '',
            timeoutSeconds: 120,
          );
      final Stream<EnvironmentProcessEvent> stream = client
          .runForegroundProcess('environment-host', request);

      expect(channel.streamCalls, 0);
      final List<EnvironmentProcessEvent> events = await stream.toList();

      expect(channel.streamCalls, 1);
      expect(channel.method, environmentProviderServiceRunForegroundProcessId);
      expect(channel.payload, <String, Object?>{
        'environmentId': 'environment-host',
        'request': <String, Object?>{
          'arguments': <Object?>['status', '--short'],
          'program': 'git',
          'relativeWorkingDirectory': '',
          'timeoutSeconds': 120,
        },
      });
      expect(
        events.map((EnvironmentProcessEvent event) => event.kind),
        <EnvironmentProcessEventKind>[
          EnvironmentProcessEventKind.output,
          EnvironmentProcessEventKind.output,
          EnvironmentProcessEventKind.completed,
        ],
      );
      expect(events[0].output!.text, 'one');
      expect(events[1].output!.stream, EnvironmentProcessOutputStream.stderr);
      expect(
        events[2].completed!.termination,
        EnvironmentProcessTermination.exited,
      );
      expect(events[2].completed!.exitCode, 0);
      expect(() => stream.listen((_) {}), throwsStateError);
    },
  );

  test('generated adapters forward the foreground process stream', () async {
    final _CapturingProvider backend = _CapturingProvider(providerId);
    final GeneratedEnvironmentProvider host = GeneratedEnvironmentProvider(
      providerId: providerId,
      service: EnvironmentProviderServiceAdapter(backend),
    );
    final EnvironmentForegroundProcessRequest request =
        EnvironmentForegroundProcessRequest(
          program: 'git',
          arguments: const <String>['status'],
          relativeWorkingDirectory: '',
          timeoutSeconds: 5,
        );

    final List<EnvironmentProcessEvent> events = await host
        .runForegroundProcess(hostEnvironment.id, request)
        .toList();

    expect(backend.processEnvironmentId, hostEnvironment.id);
    expect(backend.processRequest, same(request));
    expect(events.single.completed!.exitCode, 7);
  });

  test('generated process stream forwards cancellation', () async {
    final _CancellableProcessStreamChannel channel =
        _CancellableProcessStreamChannel();
    final EnvironmentProcessEvent event =
        await EnvironmentProviderServiceClient(channel)
            .runForegroundProcess(
              'environment-host',
              EnvironmentForegroundProcessRequest(
                program: 'git',
                arguments: const <String>['status'],
                relativeWorkingDirectory: '',
                timeoutSeconds: 5,
              ),
            )
            .first;

    expect(event.output!.text, 'started');
    expect(channel.cancellations, 1);
  });

  test('generated process stream reconstructs declared failures', () async {
    final EnvironmentProviderServiceClient client =
        EnvironmentProviderServiceClient(
          _ProcessFailureChannel(
            const _RemoteFailure(
              declaredFailureType: environmentFailureTypeId,
              code: 'process_start_failed',
              message: 'The process could not be started.',
              details: <String, Object?>{'program': 'missing'},
            ),
          ),
        );

    await expectLater(
      client.runForegroundProcess(
        'environment-host',
        EnvironmentForegroundProcessRequest(
          program: 'missing',
          arguments: const <String>[],
          relativeWorkingDirectory: '',
          timeoutSeconds: 5,
        ),
      ),
      emitsError(
        isA<EnvironmentFailure>().having(
          (EnvironmentFailure failure) => failure.code,
          'code',
          'process_start_failed',
        ),
      ),
    );
  });

  test('generated client reconstructs declared replacement failures', () async {
    final EnvironmentProviderServiceClient client =
        EnvironmentProviderServiceClient(
          _FailureChannel(
            _RemoteFailure(
              declaredFailureType: environmentFailureTypeId,
              code: 'revision_conflict',
              message: 'The expected revision no longer matches.',
              details: <String, Object?>{'relativePath': 'lib/main.dart'},
            ),
          ),
        );

    await expectLater(
      client.replaceExistingTextFile(
        'environment-host',
        'lib/main.dart',
        'replacement',
        'stale-revision',
      ),
      throwsA(
        isA<EnvironmentFailure>()
            .having(
              (EnvironmentFailure failure) => failure.code,
              'code',
              'revision_conflict',
            )
            .having(
              (EnvironmentFailure failure) => failure.details['relativePath'],
              'relativePath',
              'lib/main.dart',
            ),
      ),
    );
  });

  test('backend adapter rejects a context for another provider', () async {
    final ProviderId otherProviderId = ProviderId(
      'dev.adele.environment.other-fixture',
    );
    final GeneratedEnvironmentProvider host = GeneratedEnvironmentProvider(
      providerId: providerId,
      service: EnvironmentProviderServiceAdapter(
        _CapturingProvider(otherProviderId),
      ),
    );

    expect(
      () => host.establish(
        LocalEnvironment(
          project: hostProject,
          task: hostTask,
          value: hostEnvironment,
        ),
      ),
      throwsA(
        isA<EnvironmentFailure>().having(
          (EnvironmentFailure failure) => failure.code,
          'code',
          'invalid_context',
        ),
      ),
    );
  });
}

final class _CapturingProvider implements EnvironmentProvider {
  _CapturingProvider(this.providerId);

  @override
  final ProviderId providerId;
  LocalEnvironment? established;
  LocalEnvironment? restored;
  EnvironmentId? processEnvironmentId;
  EnvironmentForegroundProcessRequest? processRequest;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async {
    established = environment;
    return EnvironmentProviderResult(
      providerState: <String, Object?>{'fixture': true},
    );
  }

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    restored = environment;
    return EnvironmentProviderResult(providerState: environment.providerState!);
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) => throw UnimplementedError();

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => throw UnimplementedError();

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
  ) {
    processEnvironmentId = environmentId;
    processRequest = request;
    return Stream<EnvironmentProcessEvent>.value(
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

final class _ProcessStreamChannel implements AdeleStreamChannel {
  int streamCalls = 0;
  String? method;
  Map<String, Object?>? payload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      throw UnimplementedError();

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) => (() {
    streamCalls++;
    this.method = method;
    this.payload = payload;
    return Stream<Object?>.fromIterable(<Object?>[
      <String, Object?>{
        'kind': 'output',
        'output': <String, Object?>{'stream': 'stdout', 'text': 'one'},
        'completed': null,
      },
      <String, Object?>{
        'kind': 'output',
        'output': <String, Object?>{'stream': 'stderr', 'text': 'two'},
        'completed': null,
      },
      <String, Object?>{
        'kind': 'completed',
        'output': null,
        'completed': <String, Object?>{
          'termination': 'exited',
          'exitCode': 0,
          'stdoutTruncated': false,
          'stderrTruncated': false,
        },
      },
    ]);
  })();
}

final class _CancellableProcessStreamChannel implements AdeleStreamChannel {
  int cancellations = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      throw UnimplementedError();

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) {
    late final StreamController<Object?> controller;
    controller = StreamController<Object?>(
      onListen: () => controller.add(<String, Object?>{
        'kind': 'output',
        'output': <String, Object?>{'stream': 'stdout', 'text': 'started'},
        'completed': null,
      }),
      onCancel: () => cancellations++,
    );
    return controller.stream;
  }
}

final class _ProcessFailureChannel implements AdeleStreamChannel {
  const _ProcessFailureChannel(this.failure);

  final AdeleRemoteFailure failure;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async =>
      throw UnimplementedError();

  @override
  Stream<Object?> stream(String method, Map<String, Object?> payload) =>
      Stream<Object?>.error(failure);
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.response);

  final Object? response;
  String? method;
  Map<String, Object?>? payload;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    return response;
  }
}

final class _FailureChannel implements AdeleRequestChannel {
  const _FailureChannel(this.failure);

  final AdeleRemoteFailure failure;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) =>
      Future<Object?>.error(failure);
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure({
    required this.declaredFailureType,
    required this.code,
    required this.message,
    required this.details,
  });

  @override
  final String? declaredFailureType;

  @override
  final String code;

  @override
  final String message;

  @override
  final Map<String, Object?> details;
}
