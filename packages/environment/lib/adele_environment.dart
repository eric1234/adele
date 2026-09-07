/// Common ADELE Environment provider capability and contract.
library;

import 'package:adele_capabilities/adele_capabilities.dart' as capabilities;
import 'package:adele_contract/adele_contract.dart';
import 'package:adele_product/adele_product.dart' as product;

part 'adele_environment.g.dart';

/// Failure code for a create-new operation whose target already exists.
const String environmentFileAlreadyExistsCode = 'file_already_exists';

/// Failure code for a rejected stale conditional text-file mutation.
const String environmentRevisionConflictCode = 'revision_conflict';

final capabilities.CapabilityKey environmentProviderCapability =
    capabilities.CapabilityKey(
      id: capabilities.CapabilityId('dev.adele.environment.provider'),
      majorVersion: 1,
    );

enum EnvironmentDirectoryEntryKind { file, directory, other }

enum EnvironmentProcessEventKind { output, completed }

enum EnvironmentProcessOutputStream { stdout, stderr }

enum EnvironmentProcessTermination { exited, timedOut }

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
    required this.revision,
  });

  final String relativePath;
  final String text;
  final int sizeBytes;

  /// Provider-produced opaque identity for this observed file state.
  final String revision;
}

@AdeleValue('environment.textFileReplacement')
final class EnvironmentTextFileReplacement {
  const EnvironmentTextFileReplacement({required this.revision});

  /// Provider-produced opaque identity for the replacement file state.
  final String revision;
}

@AdeleValue('environment.textFileCreation')
final class EnvironmentTextFileCreation {
  EnvironmentTextFileCreation({required this.revision}) {
    if (revision.isEmpty) {
      throw const FormatException('Created file revision must not be empty.');
    }
  }

  /// Provider-produced opaque identity for the newly created file state.
  final String revision;
}

@AdeleValue('environment.foregroundProcessRequest')
final class EnvironmentForegroundProcessRequest {
  EnvironmentForegroundProcessRequest({
    required this.program,
    required List<String> arguments,
    required this.relativeWorkingDirectory,
    required this.timeoutSeconds,
  }) : arguments = List<String>.unmodifiable(arguments) {
    if (program.isEmpty) {
      throw const FormatException('Process program must not be empty.');
    }
    _requireProcessText('Process program', program);
    for (final String argument in this.arguments) {
      _requireProcessText('Process argument', argument);
    }
    _requireProcessText(
      'Process relative working directory',
      relativeWorkingDirectory,
    );
    if (timeoutSeconds < 1 || timeoutSeconds > 600) {
      throw const FormatException(
        'Process timeout must be between 1 and 600 seconds.',
      );
    }
  }

  /// Executable name or path passed directly to the provider process API.
  final String program;

  /// Ordered arguments passed verbatim without implicit shell interpretation.
  final List<String> arguments;

  /// Environment-relative directory, or empty for the Environment root.
  final String relativeWorkingDirectory;

  final int timeoutSeconds;
}

@AdeleValue('environment.processOutput')
final class EnvironmentProcessOutput {
  EnvironmentProcessOutput({required this.stream, required this.text}) {
    if (text.isEmpty) {
      throw const FormatException('Process output must not be empty.');
    }
    _requireWellFormedUnicode('Process output', text);
  }

  final EnvironmentProcessOutputStream stream;
  final String text;
}

@AdeleValue('environment.processCompleted')
final class EnvironmentProcessCompleted {
  EnvironmentProcessCompleted({
    required this.termination,
    required this.exitCode,
    required this.stdoutTruncated,
    required this.stderrTruncated,
  }) {
    if ((termination == EnvironmentProcessTermination.exited) !=
        (exitCode != null)) {
      throw const FormatException(
        'Exited processes require an exit code and timed-out processes do not.',
      );
    }
  }

  final EnvironmentProcessTermination termination;
  final int? exitCode;
  final bool stdoutTruncated;
  final bool stderrTruncated;
}

@AdeleValue('environment.processEvent')
final class EnvironmentProcessEvent {
  EnvironmentProcessEvent({
    required this.kind,
    required this.output,
    required this.completed,
  }) {
    if ((kind == EnvironmentProcessEventKind.output) != (output != null) ||
        (kind == EnvironmentProcessEventKind.completed) !=
            (completed != null)) {
      throw const FormatException(
        'Process event kind must match exactly one event payload.',
      );
    }
  }

  final EnvironmentProcessEventKind kind;
  final EnvironmentProcessOutput? output;
  final EnvironmentProcessCompleted? completed;
}

/// Identity and liveness shared by views over one Session-selected Environment.
abstract interface class AuthorizedEnvironmentAuthority {
  product.SessionId get sessionId;
  product.EnvironmentId get environmentId;

  void validateBinding();
}

/// Compatibility base for filesystem views over one authorized Environment.
abstract interface class AuthorizedEnvironmentFileSystem
    implements AuthorizedEnvironmentAuthority {}

/// Read operations over one authorized Environment filesystem.
abstract interface class AuthorizedEnvironmentFileReadFacet
    implements AuthorizedEnvironmentFileSystem {
  Future<EnvironmentTextFile> readFile(String relativePath);

  Future<EnvironmentDirectoryListing> readDirectory(String relativePath);
}

/// Mutation operations over the same authorized Environment filesystem.
abstract interface class AuthorizedEnvironmentFileMutationFacet
    implements AuthorizedEnvironmentFileSystem {
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  );

  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  );

  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  );
}

/// Foreground process operations over the same authorized Environment.
abstract interface class AuthorizedEnvironmentProcessFacet
    implements AuthorizedEnvironmentAuthority {
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  );
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

  /// Creates a text file only when no filesystem entity occupies its path.
  ///
  /// An existing target fails with [environmentFileAlreadyExistsCode].
  @AdeleMethod('createTextFile')
  Future<EnvironmentTextFileCreation> createTextFile(
    String environmentId,
    String relativePath,
    String text,
  );

  /// Replaces an existing text file only when its opaque revision matches.
  ///
  /// A detected mismatch fails with [environmentRevisionConflictCode].
  @AdeleMethod('replaceExistingTextFile')
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  );

  /// Deletes an existing text file only when its opaque revision matches.
  ///
  /// A detected mismatch fails with [environmentRevisionConflictCode].
  @AdeleMethod('deleteExistingTextFile')
  Future<void> deleteExistingTextFile(
    String environmentId,
    String relativePath,
    String expectedRevision,
  );

  @AdeleMethod('readDirectory')
  Future<EnvironmentDirectoryListing> readDirectory(
    String environmentId,
    String relativePath,
  );

  @AdeleMethod('runForegroundProcess')
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    String environmentId,
    EnvironmentForegroundProcessRequest request,
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

/// One coherent Environment lifecycle, filesystem, and process provider surface.
abstract interface class EnvironmentProvider {
  capabilities.ProviderId get providerId;

  Future<EnvironmentProviderResult> establish(LocalEnvironment environment);

  Future<EnvironmentProviderResult> restore(LocalEnvironment environment);

  Future<EnvironmentTextFile> readFile(
    product.EnvironmentId environmentId,
    String relativePath,
  );

  /// Creates a text file only when no filesystem entity occupies its path.
  ///
  /// An existing target fails with [environmentFileAlreadyExistsCode].
  Future<EnvironmentTextFileCreation> createTextFile(
    product.EnvironmentId environmentId,
    String relativePath,
    String text,
  );

  /// Replaces an existing text file only when its opaque revision matches.
  ///
  /// A detected mismatch fails with [environmentRevisionConflictCode].
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    product.EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  );

  /// Deletes an existing text file only when its opaque revision matches.
  ///
  /// A detected mismatch fails with [environmentRevisionConflictCode].
  Future<void> deleteExistingTextFile(
    product.EnvironmentId environmentId,
    String relativePath,
    String expectedRevision,
  );

  Future<EnvironmentDirectoryListing> readDirectory(
    product.EnvironmentId environmentId,
    String relativePath,
  );

  Stream<EnvironmentProcessEvent> runForegroundProcess(
    product.EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
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
  Future<EnvironmentTextFileCreation> createTextFile(
    product.EnvironmentId environmentId,
    String relativePath,
    String text,
  ) => _service.createTextFile(environmentId.value, relativePath, text);

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    product.EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => _service.replaceExistingTextFile(
    environmentId.value,
    relativePath,
    replacementText,
    expectedRevision,
  );

  @override
  Future<void> deleteExistingTextFile(
    product.EnvironmentId environmentId,
    String relativePath,
    String expectedRevision,
  ) => _service.deleteExistingTextFile(
    environmentId.value,
    relativePath,
    expectedRevision,
  );

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    product.EnvironmentId environmentId,
    String relativePath,
  ) => _service.readDirectory(environmentId.value, relativePath);

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    product.EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
  ) => _service.runForegroundProcess(environmentId.value, request);

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
  Future<EnvironmentTextFileCreation> createTextFile(
    String environmentId,
    String relativePath,
    String text,
  ) => _provider.createTextFile(
    _environmentId(environmentId),
    relativePath,
    text,
  );

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => _provider.replaceExistingTextFile(
    _environmentId(environmentId),
    relativePath,
    replacementText,
    expectedRevision,
  );

  @override
  Future<void> deleteExistingTextFile(
    String environmentId,
    String relativePath,
    String expectedRevision,
  ) => _provider.deleteExistingTextFile(
    _environmentId(environmentId),
    relativePath,
    expectedRevision,
  );

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    String environmentId,
    String relativePath,
  ) => _provider.readDirectory(_environmentId(environmentId), relativePath);

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    String environmentId,
    EnvironmentForegroundProcessRequest request,
  ) => _provider.runForegroundProcess(_environmentId(environmentId), request);

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

void _requireProcessText(String label, String value) {
  if (value.contains('\u0000')) {
    throw FormatException('$label must not contain NUL.');
  }
  _requireWellFormedUnicode(label, value);
}

void _requireWellFormedUnicode(String label, String value) {
  for (int index = 0; index < value.length; index++) {
    final int codeUnit = value.codeUnitAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (++index < value.length) {
        final int next = value.codeUnitAt(index);
        if (next >= 0xdc00 && next <= 0xdfff) continue;
      }
      throw FormatException('$label must contain well-formed Unicode text.');
    }
    if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      throw FormatException('$label must contain well-formed Unicode text.');
    }
  }
}
