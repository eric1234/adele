import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

import 'foreground_process.dart';
import 'ids.dart';
import 'worktree_environment.dart';

const int gitEnvironmentProviderStateSchemaVersion = 2;

// Git documents repository-local entries through `rev-parse --local-env-vars`.
const Set<String> _gitEnvironmentVariablesToClear = <String>{
  'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_CEILING_DIRECTORIES',
  'GIT_COMMON_DIR',
  'GIT_CONFIG',
  'GIT_CONFIG_COUNT',
  'GIT_CONFIG_PARAMETERS',
  'GIT_DIR',
  'GIT_DISCOVERY_ACROSS_FILESYSTEM',
  'GIT_GRAFT_FILE',
  'GIT_IMPLICIT_WORK_TREE',
  'GIT_INDEX_FILE',
  'GIT_NO_REPLACE_OBJECTS',
  'GIT_OBJECT_DIRECTORY',
  'GIT_PREFIX',
  'GIT_REPLACE_REF_BASE',
  'GIT_SHALLOW_FILE',
  'GIT_WORK_TREE',
};

final class GitWorktreeEnvironmentProvider implements EnvironmentProvider {
  GitWorktreeEnvironmentProvider({
    LiveObjectRegistry<EnvironmentId, WorktreeEnvironment>? liveObjects,
  }) : liveObjects =
           liveObjects ??
           LiveObjectRegistry<EnvironmentId, WorktreeEnvironment>();

  @override
  final ProviderId providerId = ProviderId(gitWorktreeEnvironmentProviderId);
  final LiveObjectRegistry<EnvironmentId, WorktreeEnvironment> liveObjects;
  final GitForegroundProcessSupervisor _processes =
      GitForegroundProcessSupervisor();
  Future<void>? _closeFuture;

  @override
  Future<EnvironmentProviderResult> establish(
    LocalEnvironment environment,
  ) async {
    if (environment.providerState != null) {
      throw _environmentFailure(
        'invalid_provider_state',
        'A new Environment must not already have provider state.',
        environmentId: environment.id,
      );
    }
    _requireAvailableId(environment.id);
    final _GitSource source = await _sourceFor(
      environment.task.project.sourceLocation,
    );
    final _GitRepository repository = source.repository;
    final String baselineCommit = await _gitOutput(
      repository.root,
      const <String>['rev-parse', 'HEAD'],
      code: 'invalid_git_source',
      message: 'The Git source does not have a baseline commit.',
    );
    final _GitResourceNames resources = await _allocateGitResourceNames(
      source,
      environment,
    );
    final String branch = resources.branch;
    final String worktreePath = _scopeWithinWorktree(
      source.scope,
      resources.worktreeRelativePath,
    ).path;
    bool branchCreated = false;
    bool worktreeAddAttempted = false;
    try {
      await _providerDirectory(source.scope, '.adele/worktrees');
      await _gitOutput(
        repository.root,
        <String>['branch', branch, baselineCommit],
        code: 'worktree_establishment_failed',
        message: 'Git could not create the Task branch.',
      );
      branchCreated = true;
      await _providerDirectory(source.scope, '.adele/worktrees');
      if (await FileSystemEntity.type(worktreePath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw _environmentFailure(
          'worktree_establishment_failed',
          'The allocated Task worktree path is no longer available.',
          environmentId: environment.id,
        );
      }
      worktreeAddAttempted = true;
      await _gitOutput(
        repository.root,
        <String>['worktree', 'add', worktreePath, branch],
        code: 'worktree_establishment_failed',
        message: 'Git could not create the Task worktree.',
      );
      final Directory worktreeRoot = await _providerDirectory(
        source.scope,
        resources.worktreeRelativePath,
      );
      final WorktreeEnvironment live = _scopedWorktreeEnvironment(
        environmentId: environment.id,
        worktreeRoot: worktreeRoot,
        relativePath: source.relativePath,
        failureCode: 'worktree_establishment_failed',
        failureMessage:
            'The Task worktree does not contain the Project source scope.',
      );
      liveObjects.bind(environment.id, live);
      return EnvironmentProviderResult(
        providerState: _providerState(
          environmentId: environment.id,
          source: source,
          worktreeRelativePath: resources.worktreeRelativePath,
          branch: branch,
          baselineCommit: baselineCommit,
        ),
      );
    } on Object catch (error) {
      await _cleanupFailedEstablishment(
        source,
        resources.worktreeRelativePath,
        branch,
        baselineCommit: baselineCommit,
        branchCreated: branchCreated,
        worktreeAddAttempted: worktreeAddAttempted,
      );
      if (error is EnvironmentFailure) rethrow;
      throw _environmentFailure(
        'worktree_establishment_failed',
        'The Task worktree could not be established.',
        environmentId: environment.id,
        details: <String, Object?>{'reason': error.toString()},
      );
    }
  }

  @override
  Future<EnvironmentProviderResult> restore(
    LocalEnvironment environment,
  ) async {
    _requireAvailableId(environment.id);
    final _GitProviderState state = _GitProviderState.parse(
      environment.id,
      environment.providerState,
    );
    final _GitSource source = await _sourceFor(
      environment.task.project.sourceLocation,
    );
    final _GitRepository repository = source.repository;
    if (source.relativePath != state.sourceRelativePath) {
      throw _environmentFailure(
        'restore_source_mismatch',
        'The retained worktree belongs to another Project source.',
        environmentId: environment.id,
      );
    }
    final Directory worktreeRoot = await _providerDirectory(
      source.scope,
      state.worktreeRelativePath,
    );
    if (await FileSystemEntity.type(
          _childPath(worktreeRoot.path, '.git'),
          followLinks: false,
        ) !=
        FileSystemEntityType.file) {
      throw _environmentFailure(
        'restore_worktree_invalid',
        'The retained path must contain a direct linked-worktree gitfile.',
        environmentId: environment.id,
      );
    }
    await _restoreRegistration(
      environment.id,
      repository,
      worktreeRoot,
      state.branch,
    );
    await _providerDirectory(source.scope, state.worktreeRelativePath);
    final _GitRepository worktree = await _inspectRepository(
      worktreeRoot,
      failureCode: 'restore_worktree_invalid',
      failureMessage: 'The retained path is not a usable Git worktree.',
    );
    if (worktree.root.path != worktreeRoot.path ||
        worktree.commonDirectory.path != repository.commonDirectory.path) {
      throw _environmentFailure(
        'restore_worktree_mismatch',
        'The retained path is not the expected linked Git worktree.',
        environmentId: environment.id,
      );
    }
    await _requireLinkedWorktree(
      environment.id,
      worktreeRoot,
      repository.commonDirectory,
    );
    final String branchRef = await _gitOutput(
      worktreeRoot,
      const <String>['symbolic-ref', '--quiet', 'HEAD'],
      code: 'restore_branch_invalid',
      message: 'The retained Git worktree is not on its expected branch.',
    );
    final String expectedBranchRef = 'refs/heads/${state.branch}';
    if (branchRef != expectedBranchRef) {
      throw _environmentFailure(
        'restore_branch_mismatch',
        'The retained Git worktree branch changed unexpectedly.',
        environmentId: environment.id,
        details: <String, Object?>{
          'expectedBranchRef': expectedBranchRef,
          'actualBranchRef': branchRef,
        },
      );
    }
    final String resolvedBaseline = await _gitOutput(
      worktreeRoot,
      <String>['rev-parse', '--verify', '${state.baselineCommit}^{commit}'],
      code: 'restore_baseline_missing',
      message: 'The retained baseline commit is unavailable.',
    );
    if (resolvedBaseline != state.baselineCommit) {
      throw _environmentFailure(
        'invalid_provider_state',
        'The retained baseline is not an exact commit identity.',
        environmentId: environment.id,
      );
    }
    final WorktreeEnvironment live = _scopedWorktreeEnvironment(
      environmentId: environment.id,
      worktreeRoot: worktreeRoot,
      relativePath: source.relativePath,
      failureCode: 'restore_source_scope_missing',
      failureMessage:
          'The retained worktree does not contain the Project source scope.',
    );
    liveObjects.bind(environment.id, live);
    return EnvironmentProviderResult(
      providerState: _providerState(
        environmentId: environment.id,
        source: source,
        worktreeRelativePath: state.worktreeRelativePath,
        branch: state.branch,
        baselineCommit: state.baselineCommit,
      ),
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(
    EnvironmentId environmentId,
    String relativePath,
  ) => _resolve(environmentId).readFile(relativePath);

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String text,
  ) => _resolve(environmentId).createTextFile(relativePath, text);

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => _resolve(
    environmentId,
  ).replaceExistingTextFile(relativePath, replacementText, expectedRevision);

  @override
  Future<void> deleteExistingTextFile(
    EnvironmentId environmentId,
    String relativePath,
    String expectedRevision,
  ) => _resolve(
    environmentId,
  ).deleteExistingTextFile(relativePath, expectedRevision);

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => _resolve(environmentId).readDirectory(relativePath);

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentId environmentId,
    EnvironmentForegroundProcessRequest request,
  ) => _processes.run(
    environmentId: environmentId,
    environment: _resolve(environmentId),
    request: request,
  );

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    await _processes.close();
    liveObjects.clear();
  }

  WorktreeEnvironment _resolve(EnvironmentId id) {
    try {
      return liveObjects.resolve(id);
    } on StateError {
      throw _environmentFailure(
        'environment_not_live',
        'The Environment is not live in this provider generation.',
        environmentId: id,
      );
    }
  }

  void _requireAvailableId(EnvironmentId id) {
    if (liveObjects.contains(id)) {
      throw _environmentFailure(
        'environment_already_live',
        'The Environment is already live in this provider generation.',
        environmentId: id,
      );
    }
  }
}

final class _GitRepository {
  const _GitRepository({required this.root, required this.commonDirectory});

  final Directory root;
  final Directory commonDirectory;
}

final class _GitResourceNames {
  const _GitResourceNames({
    required this.branch,
    required this.worktreeRelativePath,
  });

  final String branch;
  final String worktreeRelativePath;
}

enum _WorktreeRegistrationState { registered, notRegistered, unknown }

typedef _GitWorktreeRegistration = ({
  String path,
  String? branchRef,
  String? head,
});

final class _GitSource {
  const _GitSource({
    required this.scope,
    required this.repository,
    required this.relativePath,
  });

  final Directory scope;
  final _GitRepository repository;
  final String relativePath;
}

final class _GitProviderState {
  const _GitProviderState({
    required this.sourceRelativePath,
    required this.worktreeRelativePath,
    required this.branch,
    required this.baselineCommit,
  });

  factory _GitProviderState.parse(
    EnvironmentId environmentId,
    Map<String, Object?>? state,
  ) {
    const fields = <String>{
      'schemaVersion',
      'environmentId',
      'sourceRelativePath',
      'worktreeRelativePath',
      'branch',
      'baselineCommit',
    };
    if (state == null ||
        state.length != fields.length ||
        !state.keys.every(fields.contains) ||
        state['schemaVersion'] is! int ||
        state['schemaVersion'] != gitEnvironmentProviderStateSchemaVersion) {
      throw _environmentFailure(
        'invalid_provider_state',
        'The Git Environment provider state is absent or unsupported.',
        environmentId: environmentId,
      );
    }
    String requireString(String name, {bool allowEmpty = false}) {
      final Object? value = state[name];
      if (value is! String ||
          (!allowEmpty && value.isEmpty) ||
          (name != 'environmentId' &&
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(value))) {
        throw _environmentFailure(
          'invalid_provider_state',
          'The Git Environment provider state is malformed.',
          environmentId: environmentId,
          details: <String, Object?>{'field': name},
        );
      }
      return value;
    }

    final String retainedEnvironmentId = requireString('environmentId');
    if (retainedEnvironmentId != environmentId.value) {
      throw _environmentFailure(
        'restore_environment_mismatch',
        'The provider state belongs to another Environment.',
        environmentId: environmentId,
      );
    }

    final String sourceRelativePath = requireString(
      'sourceRelativePath',
      allowEmpty: true,
    );
    final String worktreeRelativePath = requireString('worktreeRelativePath');
    final String branch = requireString('branch');
    final String baselineCommit = requireString('baselineCommit');
    if (!_validSourceRelativePath(sourceRelativePath) ||
        !RegExp(
          r'^\.adele/worktrees/[a-z0-9][a-z0-9-]*$',
        ).hasMatch(worktreeRelativePath) ||
        !RegExp(r'^adele-[a-z0-9-]+$').hasMatch(branch) ||
        !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(baselineCommit)) {
      throw _environmentFailure(
        'invalid_provider_state',
        'The Git Environment provider state contains invalid paths or Git identities.',
        environmentId: environmentId,
      );
    }
    return _GitProviderState(
      sourceRelativePath: sourceRelativePath,
      worktreeRelativePath: worktreeRelativePath,
      branch: branch,
      baselineCommit: baselineCommit,
    );
  }

  final String sourceRelativePath;
  final String worktreeRelativePath;
  final String branch;
  final String baselineCommit;
}

bool _validSourceRelativePath(String value) =>
    value.isEmpty ||
    (!RegExp(r'[\\:\x00-\x1f\x7f]').hasMatch(value) &&
        value
            .split('/')
            .every(
              (String component) =>
                  component.isNotEmpty && component != '.' && component != '..',
            ));

Future<_GitSource> _sourceFor(Uri sourceLocation) async {
  if (sourceLocation.scheme != 'file') {
    throw EnvironmentFailure(
      code: 'unsupported_source_scheme',
      message: 'Git worktree Environments require a file source URI.',
      details: <String, Object?>{'scheme': sourceLocation.scheme},
    );
  }
  final String sourcePath;
  try {
    sourcePath = sourceLocation.toFilePath();
  } on UnsupportedError catch (error) {
    throw EnvironmentFailure(
      code: 'invalid_source_uri',
      message: 'The file source URI cannot be resolved on this host.',
      details: <String, Object?>{'reason': error.message},
    );
  }
  if (!_isAbsolutePath(sourcePath)) {
    throw EnvironmentFailure(
      code: 'invalid_source_uri',
      message:
          'Git worktree Environments require an absolute local file source.',
      details: <String, Object?>{'sourceLocation': sourceLocation.toString()},
    );
  }
  final Directory source;
  try {
    source = Directory(
      await Directory(sourcePath).absolute.resolveSymbolicLinks(),
    );
  } on FileSystemException {
    throw const EnvironmentFailure(
      code: 'invalid_git_source',
      message: 'The local Project source directory does not exist.',
      details: <String, Object?>{},
    );
  }
  final _GitRepository repository = await _inspectRepository(
    source,
    failureCode: 'invalid_git_source',
    failureMessage: 'The local Project source is not a usable Git worktree.',
  );
  final String relativePath = _relativePathWithin(
    repository.root,
    source,
    failureCode: 'invalid_git_source',
    failureMessage: 'The local Project source is outside its Git worktree.',
  );
  if (!_validSourceRelativePath(relativePath)) {
    throw const EnvironmentFailure(
      code: 'invalid_git_source',
      message:
          'The Project source scope cannot be retained as a portable path.',
      details: <String, Object?>{},
    );
  }
  return _GitSource(
    scope: source,
    repository: repository,
    relativePath: relativePath,
  );
}

Future<_GitRepository> _inspectRepository(
  Directory source, {
  required String failureCode,
  required String failureMessage,
}) async {
  final String rootPath = await _gitOutput(
    source,
    const <String>['rev-parse', '--show-toplevel'],
    code: failureCode,
    message: failureMessage,
  );
  final Directory root;
  try {
    root = Directory(await Directory(rootPath).resolveSymbolicLinks());
  } on FileSystemException {
    throw EnvironmentFailure(
      code: failureCode,
      message: failureMessage,
      details: const <String, Object?>{},
    );
  }
  final String commonPath = await _gitOutput(
    root,
    const <String>['rev-parse', '--git-common-dir'],
    code: failureCode,
    message: failureMessage,
  );
  final Directory commonCandidate = Directory(
    _isAbsolutePath(commonPath)
        ? commonPath
        : _childPath(root.path, commonPath),
  );
  final Directory common;
  try {
    common = Directory(await commonCandidate.resolveSymbolicLinks());
  } on FileSystemException {
    throw EnvironmentFailure(
      code: failureCode,
      message: failureMessage,
      details: const <String, Object?>{},
    );
  }
  return _GitRepository(root: root, commonDirectory: common);
}

String _relativePathWithin(
  Directory root,
  Directory source, {
  required String failureCode,
  required String failureMessage,
}) {
  if (source.path == root.path) return '';
  final String rootPrefix = root.path.endsWith(Platform.pathSeparator)
      ? root.path
      : '${root.path}${Platform.pathSeparator}';
  if (!source.path.startsWith(rootPrefix)) {
    throw EnvironmentFailure(
      code: failureCode,
      message: failureMessage,
      details: const <String, Object?>{},
    );
  }
  return source.path
      .substring(rootPrefix.length)
      .split(Platform.pathSeparator)
      .join('/');
}

Directory _scopeWithinWorktree(Directory worktree, String relativePath) =>
    relativePath.isEmpty
    ? worktree
    : Directory(
        <String>[
          worktree.path,
          ...relativePath.split('/'),
        ].join(Platform.pathSeparator),
      );

Future<Directory> _providerDirectory(
  Directory source,
  String relativePath, {
  bool create = false,
}) async {
  Directory current = source;
  try {
    for (final String component in relativePath.split('/')) {
      current = Directory(_childPath(current.path, component));
      FileSystemEntityType type = await FileSystemEntity.type(
        current.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound && create) {
        await current.create();
        type = await FileSystemEntity.type(current.path, followLinks: false);
      }
      if (type == FileSystemEntityType.notFound) {
        throw const EnvironmentFailure(
          code: 'restore_worktree_missing',
          message: 'The retained Git worktree is unavailable.',
          details: <String, Object?>{},
        );
      }
      if (type != FileSystemEntityType.directory ||
          !_sameLocalPath(await current.resolveSymbolicLinks(), current.path)) {
        throw const EnvironmentFailure(
          code: 'invalid_worktree_storage',
          message: 'Git provider storage must use direct Project directories.',
          details: <String, Object?>{},
        );
      }
      _relativePathWithin(
        source,
        current,
        failureCode: 'invalid_worktree_storage',
        failureMessage: 'Git provider storage must remain within the Project.',
      );
    }
    return current;
  } on FileSystemException catch (error) {
    throw EnvironmentFailure(
      code: 'invalid_worktree_storage',
      message: 'Git provider storage could not be validated.',
      details: <String, Object?>{'reason': error.message},
    );
  }
}

WorktreeEnvironment _scopedWorktreeEnvironment({
  required EnvironmentId environmentId,
  required Directory worktreeRoot,
  required String relativePath,
  required String failureCode,
  required String failureMessage,
}) {
  final Directory expectedScope = _scopeWithinWorktree(
    worktreeRoot,
    relativePath,
  );
  final WorktreeEnvironment live;
  try {
    live = WorktreeEnvironment(expectedScope);
  } on ArgumentError catch (error) {
    throw _environmentFailure(
      failureCode,
      failureMessage,
      environmentId: environmentId,
      details: <String, Object?>{'reason': error.message.toString()},
    );
  }
  final String worktreePrefix =
      worktreeRoot.path.endsWith(Platform.pathSeparator)
      ? worktreeRoot.path
      : '${worktreeRoot.path}${Platform.pathSeparator}';
  if (live.root.path != worktreeRoot.path &&
      !live.root.path.startsWith(worktreePrefix)) {
    throw _environmentFailure(
      failureCode,
      failureMessage,
      environmentId: environmentId,
      details: <String, Object?>{
        'reason': 'source scope resolves outside worktree',
      },
    );
  }
  if (!_sameLocalPath(live.root.path, expectedScope.path)) {
    throw _environmentFailure(
      failureCode,
      failureMessage,
      environmentId: environmentId,
      details: <String, Object?>{
        'reason': 'source scope resolves to another worktree location',
      },
    );
  }
  return live;
}

Future<void> _requireLinkedWorktree(
  EnvironmentId environmentId,
  Directory worktree,
  Directory commonDirectory,
) async {
  final String gitDirectoryPath = await _gitOutput(
    worktree,
    const <String>['rev-parse', '--absolute-git-dir'],
    code: 'restore_worktree_invalid',
    message: 'The retained path is not a linked Git worktree.',
  );
  final Directory gitDirectory;
  try {
    gitDirectory = Directory(
      await Directory(gitDirectoryPath).resolveSymbolicLinks(),
    );
  } on FileSystemException {
    throw _environmentFailure(
      'restore_worktree_invalid',
      'The retained linked-worktree metadata is unavailable.',
      environmentId: environmentId,
    );
  }
  final String linkedMetadataRoot =
      '${commonDirectory.path}${Platform.pathSeparator}worktrees';
  final String linkedMetadataPrefix =
      '$linkedMetadataRoot${Platform.pathSeparator}';
  if (!gitDirectory.path.startsWith(linkedMetadataPrefix)) {
    throw _environmentFailure(
      'restore_worktree_mismatch',
      'The retained path is not a provider-managed linked Git worktree.',
      environmentId: environmentId,
    );
  }
}

Map<String, Object?> _providerState({
  required EnvironmentId environmentId,
  required _GitSource source,
  required String worktreeRelativePath,
  required String branch,
  required String baselineCommit,
}) => <String, Object?>{
  'schemaVersion': gitEnvironmentProviderStateSchemaVersion,
  'environmentId': environmentId.value,
  'sourceRelativePath': source.relativePath,
  'worktreeRelativePath': worktreeRelativePath,
  'branch': branch,
  'baselineCommit': baselineCommit,
};

String _branchName(LocalEnvironment environment) {
  final String title = _slug(environment.task.title, fallback: 'task');
  final String id = _slug(environment.id.value, fallback: 'environment');
  return 'adele-${_truncate(title, 32)}-${_truncate(id, 16)}-'
      '${_stableHash(environment.id.value)}';
}

String _worktreeRelativePath(LocalEnvironment environment) {
  final String worktreeName =
      '${_truncate(_slug(environment.task.title, fallback: 'task'), 32)}-'
      '${_truncate(_slug(environment.id.value, fallback: 'environment'), 16)}-'
      '${_stableHash(environment.id.value)}';
  return '.adele/worktrees/$worktreeName';
}

Future<_GitResourceNames> _allocateGitResourceNames(
  _GitSource source,
  LocalEnvironment environment,
) async {
  final String baseBranch = _branchName(environment);
  final String baseWorktreePath = _worktreeRelativePath(environment);
  await _providerDirectory(source.scope, '.adele/worktrees', create: true);
  for (int candidate = 1; ; candidate++) {
    final String suffix = candidate == 1 ? '' : '-$candidate';
    final String branch = '$baseBranch$suffix';
    final String relativePath = '$baseWorktreePath$suffix';
    final String worktreePath = _scopeWithinWorktree(
      source.scope,
      relativePath,
    ).path;
    if (await _branchExists(source.repository.root, branch)) continue;
    if (await FileSystemEntity.type(worktreePath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      continue;
    }
    return _GitResourceNames(
      branch: branch,
      worktreeRelativePath: relativePath,
    );
  }
}

String _slug(String value, {required String fallback}) {
  final StringBuffer result = StringBuffer();
  bool separator = false;
  for (final int codeUnit in value.toLowerCase().codeUnits) {
    final bool accepted =
        codeUnit >= 0x61 && codeUnit <= 0x7a ||
        codeUnit >= 0x30 && codeUnit <= 0x39;
    if (accepted) {
      if (separator && result.isNotEmpty) result.write('-');
      result.writeCharCode(codeUnit);
      separator = false;
    } else {
      separator = true;
    }
  }
  return result.isEmpty ? fallback : result.toString();
}

String _truncate(String value, int limit) =>
    value.length <= limit ? value : value.substring(0, limit);

String _stableHash(String value) {
  int hash = 0x811c9dc5;
  for (final int codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Future<String> _gitOutput(
  Directory workingDirectory,
  List<String> arguments, {
  required String code,
  required String message,
}) async {
  final ProcessResult result;
  try {
    result = await _runGit(workingDirectory, arguments);
  } on ProcessException catch (error) {
    throw EnvironmentFailure(
      code: 'git_unavailable',
      message: 'The Git executable is unavailable.',
      details: <String, Object?>{'reason': error.message},
    );
  }
  final String stdoutText = _stripTerminalLineEnding(result.stdout.toString());
  if (result.exitCode != 0) {
    throw EnvironmentFailure(
      code: code,
      message: message,
      details: <String, Object?>{
        'exitCode': result.exitCode,
        'gitError': _truncate(result.stderr.toString().trim(), 1000),
      },
    );
  }
  return stdoutText;
}

String _stripTerminalLineEnding(String value) {
  if (!value.endsWith('\n')) return value;
  final int lineEndingLength =
      Platform.isWindows &&
          value.length > 1 &&
          value.codeUnitAt(value.length - 2) == 0x0d
      ? 2
      : 1;
  return value.substring(0, value.length - lineEndingLength);
}

Future<bool> _branchExists(Directory repository, String branch) async {
  final ProcessResult result;
  try {
    result = await _runGit(repository, <String>[
      'show-ref',
      '--verify',
      '--quiet',
      'refs/heads/$branch',
    ]);
  } on ProcessException catch (error) {
    throw EnvironmentFailure(
      code: 'git_unavailable',
      message: 'The Git executable is unavailable.',
      details: <String, Object?>{'reason': error.message},
    );
  }
  if (result.exitCode == 0) return true;
  if (result.exitCode == 1) return false;
  throw EnvironmentFailure(
    code: 'invalid_git_source',
    message: 'Git could not inspect existing Task branches.',
    details: <String, Object?>{
      'exitCode': result.exitCode,
      'gitError': _truncate(result.stderr.toString().trim(), 1000),
    },
  );
}

Future<void> _cleanupFailedEstablishment(
  _GitSource source,
  String worktreeRelativePath,
  String branch, {
  required String baselineCommit,
  required bool branchCreated,
  required bool worktreeAddAttempted,
}) async {
  if (!branchCreated) return;
  final Directory repository = source.repository.root;
  final String worktreePath = _scopeWithinWorktree(
    source.scope,
    worktreeRelativePath,
  ).path;
  if (worktreeAddAttempted) {
    try {
      await _providerDirectory(source.scope, '.adele/worktrees');
      if (await FileSystemEntity.type(worktreePath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await _providerDirectory(source.scope, worktreeRelativePath);
      }
    } on EnvironmentFailure {
      // Never clean through a replaced storage parent or worktree alias.
      return;
    }
    final _WorktreeRegistrationState registration =
        await _worktreeRegistrationForBranch(repository, worktreePath, branch);
    if (registration == _WorktreeRegistrationState.unknown) return;
    if (registration == _WorktreeRegistrationState.registered) {
      final ProcessResult removal;
      try {
        removal = await _runGit(repository, <String>[
          'worktree',
          'remove',
          '--force',
          worktreePath,
        ]);
      } on ProcessException {
        return;
      }
      if (removal.exitCode != 0) return;
    }
  }
  try {
    await _runGit(repository, <String>[
      'update-ref',
      '-d',
      'refs/heads/$branch',
      baselineCommit,
    ]);
  } on ProcessException {
    // Best-effort cleanup after provider-owned establishment failed.
  }
}

Future<_WorktreeRegistrationState> _worktreeRegistrationForBranch(
  Directory repository,
  String worktreePath,
  String branch,
) async {
  final ProcessResult result;
  try {
    result = await _runGit(repository, const <String>[
      'worktree',
      'list',
      '--porcelain',
      '-z',
    ]);
  } on ProcessException {
    return _WorktreeRegistrationState.unknown;
  }
  if (result.exitCode != 0) return _WorktreeRegistrationState.unknown;
  for (final registration in _parseWorktreeInventory(
    result.stdout.toString(),
  )) {
    if (_sameLocalPath(registration.path, worktreePath) &&
        registration.branchRef == 'refs/heads/$branch') {
      return _WorktreeRegistrationState.registered;
    }
  }
  return _WorktreeRegistrationState.notRegistered;
}

List<_GitWorktreeRegistration> _parseWorktreeInventory(String output) {
  final registrations = <_GitWorktreeRegistration>[];
  String? path;
  String? branchRef;
  String? head;
  for (final String field in output.split('\u0000')) {
    if (field.isEmpty) {
      if (path != null) {
        registrations.add((path: path, branchRef: branchRef, head: head));
      }
      path = null;
      branchRef = null;
      head = null;
    } else if (field.startsWith('worktree ')) {
      path = field.substring('worktree '.length);
    } else if (field.startsWith('branch ')) {
      branchRef = field.substring('branch '.length);
    } else if (field.startsWith('HEAD ')) {
      head = field.substring('HEAD '.length);
    }
  }
  return registrations;
}

Future<List<_GitWorktreeRegistration>> _worktreeInventory(
  Directory repository,
) async => _parseWorktreeInventory(
  await _gitOutput(
    repository,
    const <String>['worktree', 'list', '--porcelain', '-z'],
    code: 'restore_worktree_invalid',
    message: 'Git could not inspect the retained worktree registration.',
  ),
);

Future<void> _restoreRegistration(
  EnvironmentId environmentId,
  _GitRepository repository,
  Directory worktree,
  String branch,
) async {
  final String expectedRef = 'refs/heads/$branch';
  final inventory = await _worktreeInventory(repository.root);
  final registrations = inventory
      .where((entry) => entry.branchRef == expectedRef)
      .toList();
  if (registrations.length != 1) {
    throw _environmentFailure(
      'restore_branch_mismatch',
      'Git must register exactly one worktree for the retained branch.',
      environmentId: environmentId,
    );
  }
  final String registeredPath = registrations.single.path;
  if (_sameLocalPath(registeredPath, worktree.path)) return;
  if (inventory.any((entry) => !_isAbsolutePath(entry.path))) {
    throw _environmentFailure(
      'restore_worktree_invalid',
      'Git repair requires absolute registered worktree paths.',
      environmentId: environmentId,
    );
  }
  if (!await _pathIsAbsent(registeredPath)) {
    throw _environmentFailure(
      'restore_worktree_conflict',
      'The retained branch is registered at another existing path.',
      environmentId: environmentId,
    );
  }

  await _validateRepairGitfile(
    repository,
    worktree,
    registrations.single,
    allowStale: true,
  );
  // Git repair also visits every other registered linked checkout. Validate
  // those live paths first so it cannot "fix" a foreign checkout or alias.
  for (final entry in inventory.skip(1)) {
    if (_sameLocalPath(entry.path, registeredPath) ||
        await _pathIsAbsent(entry.path)) {
      continue;
    }
    if (inventory
            .skip(1)
            .where(
              (other) =>
                  other.branchRef == entry.branchRef &&
                  other.head == entry.head,
            )
            .length !=
        1) {
      throw _environmentFailure(
        'restore_worktree_conflict',
        'Another live worktree registration is ambiguous; repair is unsafe.',
        environmentId: environmentId,
      );
    }
    await _validateRepairGitfile(repository, Directory(entry.path), entry);
  }
  final latest = await _worktreeInventory(repository.root);
  if (latest.length != inventory.length ||
      inventory.indexed.any((entry) => latest[entry.$1] != entry.$2)) {
    throw _environmentFailure(
      'restore_worktree_conflict',
      'Git worktree registrations changed during repair validation.',
      environmentId: environmentId,
    );
  }
  await _gitOutput(
    repository.root,
    <String>['worktree', 'repair', worktree.path],
    code: 'restore_worktree_repair_failed',
    message:
        'Git could not repair the moved worktree. Relocation requires '
        'Git worktree repair support.',
  );
  final repaired = (await _worktreeInventory(
    repository.root,
  )).where((entry) => entry.branchRef == expectedRef).toList();
  if (repaired.length != 1 ||
      !_sameLocalPath(repaired.single.path, worktree.path)) {
    throw _environmentFailure(
      'restore_worktree_mismatch',
      'Git repair did not register the retained branch at its expected path.',
      environmentId: environmentId,
    );
  }
}

Future<bool> _pathIsAbsent(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return false;
  }
  // A failed stat can also mean inaccessible, not missing. Confirm absence
  // against the nearest readable parent before permitting relocation writes.
  final Directory parent = Directory(path).parent;
  if (!_sameLocalPath(parent.path, path)) {
    try {
      return !await parent
          .list(followLinks: false)
          .any((entry) => _sameLocalPath(entry.path, path));
    } on FileSystemException {
      if (await _pathIsAbsent(parent.path)) return true;
    }
  }
  throw const EnvironmentFailure(
    code: 'restore_worktree_invalid',
    message: 'Git worktree path absence could not be verified safely.',
    details: <String, Object?>{},
  );
}

Future<void> _validateRepairGitfile(
  _GitRepository repository,
  Directory worktree,
  _GitWorktreeRegistration registration, {
  bool allowStale = false,
}) async {
  const String code = 'restore_worktree_mismatch';
  const String message = 'A worktree Git marker cannot be safely repaired.';
  const failure = EnvironmentFailure(
    code: code,
    message: message,
    details: <String, Object?>{},
  );
  try {
    final File gitfile = File(_childPath(worktree.path, '.git'));
    if (await FileSystemEntity.type(worktree.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !_sameLocalPath(await worktree.resolveSymbolicLinks(), worktree.path) ||
        await FileSystemEntity.type(gitfile.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw failure;
    }
    String gitDirectory;
    bool stale = false;
    try {
      // Resolve the gitfile without loading a possibly foreign configuration.
      gitDirectory = await _gitOutput(
        repository.root,
        <String>['rev-parse', '--resolve-git-dir', gitfile.path],
        code: code,
        message: message,
      );
    } on EnvironmentFailure catch (error) {
      if (!allowStale || error.code != code) rethrow;
      stale = true;
      // Inspect only the documented checkout gitfile, never private worktree
      // registration files. Git remains authoritative for branch/registration.
      if (await gitfile.length() > 16384) throw failure;
      final String marker = _stripTerminalLineEnding(
        await gitfile.readAsString(),
      );
      if (!marker.startsWith('gitdir: ')) throw failure;
      final String target = marker.substring('gitdir: '.length);
      final String oldGitDirectory = _isAbsolutePath(target)
          ? target
          : _childPath(worktree.path, target);
      if (!await _pathIsAbsent(oldGitDirectory)) {
        throw failure;
      }
      final String id = target
          .split(Platform.isWindows ? RegExp(r'[\\/]') : '/')
          .last;
      if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(id)) {
        throw failure;
      }
      gitDirectory = _childPath(
        _childPath(repository.commonDirectory.path, 'worktrees'),
        id,
      );
    }
    if (Platform.isWindows) {
      gitDirectory = gitDirectory.replaceAll('/', Platform.pathSeparator);
    }
    final String relative = _relativePathWithin(
      repository.commonDirectory,
      Directory(gitDirectory),
      failureCode: code,
      failureMessage: message,
    );
    if (relative.split('/').length != 2 || !relative.startsWith('worktrees/')) {
      throw failure;
    }
    final Directory metadata = await _providerDirectory(
      repository.commonDirectory,
      relative,
    );
    final String backlinkPath = await _gitOutput(
      repository.root,
      <String>[
        '--git-dir=${metadata.path}',
        'rev-parse',
        '--git-path',
        'gitdir',
      ],
      code: code,
      message: message,
    );
    if (!_sameLocalPath(backlinkPath, _childPath(metadata.path, 'gitdir')) ||
        await FileSystemEntity.type(backlinkPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw failure;
    }
    // Git omits unreadable/empty backlinks from inventory. Check membership
    // prerequisites without parsing private registration contents; also forbid
    // a symlink here because repair writes this file.
    final RandomAccessFile backlink = await File(backlinkPath).open();
    try {
      if (await backlink.readByte() == -1) throw failure;
    } finally {
      await backlink.close();
    }
    final String common = await _gitOutput(
      repository.root,
      <String>['--git-dir=${metadata.path}', 'rev-parse', '--git-common-dir'],
      code: code,
      message: message,
    );
    final Directory commonDirectory = Directory(
      _isAbsolutePath(common)
          ? common
          : _childPath(repository.root.path, common),
    );
    if (!_sameLocalPath(
      await commonDirectory.resolveSymbolicLinks(),
      repository.commonDirectory.path,
    )) {
      throw failure;
    }
    final String actualHead = await _gitOutput(
      repository.root,
      <String>['--git-dir=${metadata.path}', 'rev-parse', 'HEAD'],
      code: code,
      message: message,
    );
    final String actualRef = await _gitOutput(
      repository.root,
      <String>[
        '--git-dir=${metadata.path}',
        'rev-parse',
        '--symbolic-full-name',
        'HEAD',
      ],
      code: code,
      message: message,
    );
    if (actualHead != registration.head ||
        actualRef != (registration.branchRef ?? 'HEAD')) {
      throw failure;
    }
    if (!stale) {
      final _GitRepository existing = await _inspectRepository(
        worktree,
        failureCode: code,
        failureMessage: message,
      );
      if (!_sameLocalPath(existing.root.path, worktree.path) ||
          !_sameLocalPath(
            existing.commonDirectory.path,
            repository.commonDirectory.path,
          )) {
        throw failure;
      }
    }
  } on FileSystemException {
    throw failure;
  } on FormatException {
    throw failure;
  }
}

Future<ProcessResult> _runGit(
  Directory workingDirectory,
  List<String> arguments,
) {
  final Map<String, String> environment = Map<String, String>.of(
    Platform.environment,
  );
  if (Platform.isWindows) {
    environment.removeWhere(
      (String name, String _) =>
          _gitEnvironmentVariablesToClear.contains(name.toUpperCase()),
    );
  } else {
    for (final String name in _gitEnvironmentVariablesToClear) {
      environment.remove(name);
    }
  }
  return Process.run(
    'git',
    <String>['-C', workingDirectory.path, ...arguments],
    environment: environment,
    includeParentEnvironment: false,
  );
}

bool _isAbsolutePath(String path) {
  if (Platform.isWindows) {
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) ||
        path.startsWith(r'\\') ||
        path.startsWith('//');
  }
  return path.startsWith('/');
}

bool _sameLocalPath(String left, String right) {
  if (!Platform.isWindows) return left == right;
  return left.replaceAll('/', Platform.pathSeparator) ==
      right.replaceAll('/', Platform.pathSeparator);
}

String _childPath(String parent, String child) =>
    parent.endsWith(Platform.pathSeparator)
    ? '$parent$child'
    : '$parent${Platform.pathSeparator}$child';

EnvironmentFailure _environmentFailure(
  String code,
  String message, {
  required EnvironmentId environmentId,
  Map<String, Object?> details = const <String, Object?>{},
}) => EnvironmentFailure(
  code: code,
  message: message,
  details: <String, Object?>{'environmentId': environmentId.value, ...details},
);
