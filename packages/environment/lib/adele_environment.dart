/// Common ADELE Environment provider capability and contract.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_product/adele_product.dart' as product;

part 'adele_environment.g.dart';

final capabilities.CapabilityKey environmentProviderCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.environment.provider'),
      majorVersion: 1,
    );

enum EnvironmentDirectoryEntryKind { file, directory, other }

/// Closed transport snapshot used to reify one local product relationship graph.
@AdeleValue('environment.context')
final class EnvironmentTransportContext {
  EnvironmentTransportContext({
    required this.projectId,
    required this.projectSourceLocation,
    required this.taskId,
    required this.taskTitle,
    required this.environmentId,
    required this.environmentRole,
    required this.providerId,
    required this.providerStateInitialized,
    required Map<String, Object?> providerState,
  }) : providerState = adeleSnapshotJsonMap(providerState) {
    if (!providerStateInitialized && providerState.isNotEmpty) {
      throw const FormatException(
        'Uninitialized provider state must have an empty payload.',
      );
    }
  }

  final String projectId;
  final Uri projectSourceLocation;
  final String taskId;
  final String taskTitle;
  final String environmentId;
  final String environmentRole;
  final String providerId;
  final bool providerStateInitialized;
  final Map<String, Object?> providerState;
}

@AdeleValue('environment.providerResult')
final class EnvironmentProviderResult {
  EnvironmentProviderResult({required Map<String, Object?> providerState})
    : providerState = adeleSnapshotJsonMap(providerState);

  final Map<String, Object?> providerState;
}

@AdeleValue('environment.textFile')
final class EnvironmentTextFile {
  const EnvironmentTextFile({
    required this.relativePath,
    required this.text,
    required this.sizeBytes,
  });

  final String relativePath;
  final String text;
  final int sizeBytes;
}

/// Session-selected filesystem authority exposed to host-side tool plugins.
abstract interface class AuthorizedEnvironmentFileSystem {
  product.SessionId get sessionId;
  product.EnvironmentId get environmentId;

  void validateBinding();

  Future<EnvironmentTextFile> readFile(String relativePath);
}

sealed class AuthorizedEnvironmentBindingException implements Exception {
  const AuthorizedEnvironmentBindingException(this.message, {this.cause});

  final String message;
  final Object? cause;
}

final class AuthorizedEnvironmentBindingStale
    extends AuthorizedEnvironmentBindingException {
  const AuthorizedEnvironmentBindingStale(super.message, {super.cause});
}

final class AuthorizedEnvironmentBindingUnavailable
    extends AuthorizedEnvironmentBindingException {
  const AuthorizedEnvironmentBindingUnavailable(super.message, {super.cause});
}

@AdeleValue('environment.directoryEntry')
final class EnvironmentDirectoryEntry {
  const EnvironmentDirectoryEntry({
    required this.name,
    required this.relativePath,
    required this.kind,
  });

  final String name;
  final String relativePath;
  final EnvironmentDirectoryEntryKind kind;
}

@AdeleValue('environment.directoryListing')
final class EnvironmentDirectoryListing {
  EnvironmentDirectoryListing({
    required this.relativePath,
    required List<EnvironmentDirectoryEntry> entries,
  }) : entries = List<EnvironmentDirectoryEntry>.unmodifiable(entries);

  final String relativePath;
  final List<EnvironmentDirectoryEntry> entries;
}

@AdeleService('environment')
abstract interface class EnvironmentProviderService {
  @AdeleMethod('establish')
  Future<EnvironmentProviderResult> establish(
    EnvironmentTransportContext context,
  );

  @AdeleMethod('restore')
  Future<EnvironmentProviderResult> restore(
    EnvironmentTransportContext context,
  );

  @AdeleMethod('readFile')
  Future<EnvironmentTextFile> readFile(
    String environmentId,
    String relativePath,
  );

  @AdeleMethod('readDirectory')
  Future<EnvironmentDirectoryListing> readDirectory(
    String environmentId,
    String relativePath,
  );
}

@AdeleFailure('environment.failure')
final class EnvironmentFailure implements Exception {
  const EnvironmentFailure({
    required this.code,
    required this.message,
    required this.details,
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'EnvironmentFailure($code): $message';
}

/// Component-local relationship view over canonical product values.
final class LocalEnvironment {
  LocalEnvironment({
    required product.Project project,
    required product.Task task,
    required this.value,
  }) : task = LocalTask._(project: project, value: task) {
    if (task.projectId != project.id) {
      throw ArgumentError('Task does not belong to the supplied Project.');
    }
    if (value.taskId != task.id) {
      throw ArgumentError('Environment does not belong to the supplied Task.');
    }
  }

  final product.Environment value;
  final LocalTask task;

  product.EnvironmentId get id => value.id;
  product.EnvironmentRole get role => value.role;
  capabilities.ProviderId get providerId => value.providerId;
  Map<String, Object?>? get providerState => value.providerState;
}

final class LocalTask {
  const LocalTask._({required this.project, required this.value});

  final product.Project project;
  final product.Task value;

  product.TaskId get id => value.id;
  String get title => value.title;
}

/// One coherent Environment lifecycle and filesystem provider surface.
abstract interface class EnvironmentProvider {
  capabilities.ProviderId get providerId;

  Future<EnvironmentProviderResult> establish(LocalEnvironment environment);

  Future<EnvironmentProviderResult> restore(LocalEnvironment environment);

  Future<EnvironmentTextFile> readFile(
    product.EnvironmentId environmentId,
    String relativePath,
  );

  Future<EnvironmentDirectoryListing> readDirectory(
    product.EnvironmentId environmentId,
    String relativePath,
  );
}

/// Host-side adapter from a generated binding to ordinary Environment values.
final class GeneratedEnvironmentProvider implements EnvironmentProvider {
  const GeneratedEnvironmentProvider({
    required this.providerId,
    required EnvironmentProviderService service,
  }) : _service = service;

  @override
  final capabilities.ProviderId providerId;
  final EnvironmentProviderService _service;

  @override
  Future<EnvironmentProviderResult> establish(LocalEnvironment environment) {
    _requireSelectedProvider(environment);
    return _service.establish(_snapshot(environment));
  }

  @override
  Future<EnvironmentProviderResult> restore(LocalEnvironment environment) {
    _requireSelectedProvider(environment);
    if (environment.providerState == null) {
      throw EnvironmentFailure(
        code: 'invalid_provider_state',
        message: 'Restore requires initialized provider state.',
        details: <String, Object?>{'environmentId': environment.id.value},
      );
    }
    return _service.restore(_snapshot(environment));
  }

  @override
  Future<EnvironmentTextFile> readFile(
    product.EnvironmentId environmentId,
    String relativePath,
  ) => _service.readFile(environmentId.value, relativePath);

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    product.EnvironmentId environmentId,
    String relativePath,
  ) => _service.readDirectory(environmentId.value, relativePath);

  void _requireSelectedProvider(LocalEnvironment environment) {
    if (environment.providerId != providerId) {
      throw ArgumentError(
        'Environment provider ${environment.providerId} does not match '
        'selected provider $providerId.',
      );
    }
  }
}

/// Backend-side adapter that reconstructs component-local product values.
final class EnvironmentProviderServiceAdapter
    implements EnvironmentProviderService {
  const EnvironmentProviderServiceAdapter(this._provider);

  final EnvironmentProvider _provider;

  @override
  Future<EnvironmentProviderResult> establish(
    EnvironmentTransportContext context,
  ) => _provider.establish(_localEnvironment(context));

  @override
  Future<EnvironmentProviderResult> restore(
    EnvironmentTransportContext context,
  ) => _provider.restore(_localEnvironment(context));

  @override
  Future<EnvironmentTextFile> readFile(
    String environmentId,
    String relativePath,
  ) => _provider.readFile(_environmentId(environmentId), relativePath);

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    String environmentId,
    String relativePath,
  ) => _provider.readDirectory(_environmentId(environmentId), relativePath);

  LocalEnvironment _localEnvironment(EnvironmentTransportContext context) {
    final LocalEnvironment environment = _reify(context);
    if (environment.providerId != _provider.providerId) {
      throw EnvironmentFailure(
        code: 'invalid_context',
        message: 'The Environment targets another provider.',
        details: <String, Object?>{
          'environmentId': environment.id.value,
          'providerId': environment.providerId.value,
        },
      );
    }
    return environment;
  }
}

EnvironmentTransportContext _snapshot(LocalEnvironment environment) {
  final product.Task task = environment.task.value;
  final product.Project project = environment.task.project;
  return EnvironmentTransportContext(
    projectId: project.id.value,
    projectSourceLocation: project.sourceLocation,
    taskId: task.id.value,
    taskTitle: task.title,
    environmentId: environment.id.value,
    environmentRole: environment.role.name,
    providerId: environment.providerId.value,
    providerStateInitialized: environment.providerState != null,
    providerState: environment.providerState ?? const <String, Object?>{},
  );
}

LocalEnvironment _reify(EnvironmentTransportContext context) {
  try {
    final product.Project project = product.Project(
      id: product.ProjectId(context.projectId),
      sourceLocation: context.projectSourceLocation,
    );
    final product.Task task = product.Task(
      id: product.TaskId(context.taskId),
      projectId: project.id,
      title: context.taskTitle,
    );
    final product.Environment environment = product.Environment(
      id: product.EnvironmentId(context.environmentId),
      taskId: task.id,
      role: switch (context.environmentRole) {
        'primary' => product.EnvironmentRole.primary,
        'additional' => product.EnvironmentRole.additional,
        _ => throw FormatException(
          'Unknown Environment role: ${context.environmentRole}.',
        ),
      },
      providerId: capabilities.ProviderId(context.providerId),
      providerState: context.providerStateInitialized
          ? context.providerState
          : null,
    );
    return LocalEnvironment(project: project, task: task, value: environment);
  } on FormatException catch (error) {
    throw _invalidContext(context, error);
  } on ArgumentError catch (error) {
    throw _invalidContext(context, error);
  } on capabilities.CapabilityException catch (error) {
    throw _invalidContext(context, error);
  }
}

EnvironmentFailure _invalidContext(
  EnvironmentTransportContext context,
  Object error,
) => EnvironmentFailure(
  code: 'invalid_context',
  message: 'The Environment product context is invalid.',
  details: <String, Object?>{
    'environmentId': context.environmentId,
    'reason': error.toString(),
  },
);

product.EnvironmentId _environmentId(String value) {
  try {
    return product.EnvironmentId(value);
  } on FormatException catch (error) {
    throw EnvironmentFailure(
      code: 'invalid_environment_id',
      message: 'The Environment ID is invalid.',
      details: <String, Object?>{'reason': error.message},
    );
  }
}
