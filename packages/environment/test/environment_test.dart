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
