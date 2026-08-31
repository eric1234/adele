import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

import 'ids.dart';
import 'worktree_environment.dart';

const int gitEnvironmentProviderStateSchemaVersion = 1;

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
      repository.root,
      environment,
    );
    final String branch = resources.branch;
    final String worktreePath = resources.worktreePath;
    bool branchCreated = false;
    bool worktreeAddAttempted = false;
    bool worktreeAddSucceeded = false;
    try {
      await Directory(worktreePath).parent.create(recursive: true);
      await _gitOutput(
        repository.root,
        <String>['branch', branch, baselineCommit],
        code: 'worktree_establishment_failed',
        message: 'Git could not create the Task branch.',
      );
      branchCreated = true;
      worktreeAddAttempted = true;
      await _gitOutput(
        repository.root,
        <String>['worktree', 'add', worktreePath, branch],
        code: 'worktree_establishment_failed',
        message: 'Git could not create the Task worktree.',
      );
      worktreeAddSucceeded = true;
      final Directory worktreeRoot = Directory(
        await Directory(worktreePath).resolveSymbolicLinks(),
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
          worktreePath: worktreeRoot.path,
          branch: branch,
          baselineCommit: baselineCommit,
        ),
      );
    } on Object catch (error) {
      await _cleanupFailedEstablishment(
        repository.root,
        worktreePath,
        branch,
        baselineCommit: baselineCommit,
        branchCreated: branchCreated,
        worktreeAddAttempted: worktreeAddAttempted,
        worktreeAddSucceeded: worktreeAddSucceeded,
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
    if (source.scope.path != state.sourcePath ||
        repository.root.path != state.repositoryPath ||
        source.relativePath != state.sourceRelativePath ||
        repository.commonDirectory.path != state.commonGitDirectory) {
      throw _environmentFailure(
        'restore_source_mismatch',
        'The retained worktree belongs to another Project source.',
        environmentId: environment.id,
      );
    }
    final Directory worktreeRoot;
    try {
      worktreeRoot = Directory(
        await Directory(state.worktreePath).resolveSymbolicLinks(),
      );
      if (await FileSystemEntity.type(worktreeRoot.path, followLinks: true) !=
          FileSystemEntityType.directory) {
        throw FileSystemException(
          'Retained worktree is not a directory.',
          state.worktreePath,
        );
      }
    } on FileSystemException catch (error) {
      throw _environmentFailure(
        'restore_worktree_missing',
        'The retained Git worktree is unavailable.',
        environmentId: environment.id,
        details: <String, Object?>{'reason': error.message},
      );
    }
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
        worktreePath: worktreeRoot.path,
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
  Future<EnvironmentDirectoryListing> readDirectory(
    EnvironmentId environmentId,
    String relativePath,
  ) => _resolve(environmentId).readDirectory(relativePath);

  void close() => liveObjects.clear();

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
  const _GitResourceNames({required this.branch, required this.worktreePath});

  final String branch;
  final String worktreePath;
}

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
    required this.sourcePath,
    required this.repositoryPath,
    required this.sourceRelativePath,
    required this.commonGitDirectory,
    required this.worktreePath,
    required this.branch,
    required this.baselineCommit,
  });

  factory _GitProviderState.parse(
    EnvironmentId environmentId,
    Map<String, Object?>? state,
  ) {
    if (state == null ||
        state['schemaVersion'] != gitEnvironmentProviderStateSchemaVersion) {
      throw _environmentFailure(
        'invalid_provider_state',
        'The Git Environment provider state is absent or unsupported.',
        environmentId: environmentId,
      );
    }
    String requireString(String name) {
      final Object? value = state[name];
      if (value is! String || value.isEmpty) {
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

    return _GitProviderState(
      sourcePath: requireString('sourcePath'),
      repositoryPath: requireString('repositoryPath'),
      sourceRelativePath: state['sourceRelativePath'] is String
          ? state['sourceRelativePath']! as String
          : throw _environmentFailure(
              'invalid_provider_state',
              'The Git Environment provider state is malformed.',
              environmentId: environmentId,
              details: const <String, Object?>{'field': 'sourceRelativePath'},
            ),
      commonGitDirectory: requireString('commonGitDirectory'),
      worktreePath: requireString('worktreePath'),
      branch: requireString('branch'),
      baselineCommit: requireString('baselineCommit'),
    );
  }

  final String sourcePath;
  final String repositoryPath;
  final String sourceRelativePath;
  final String commonGitDirectory;
  final String worktreePath;
  final String branch;
  final String baselineCommit;
}

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
  required String worktreePath,
  required String branch,
  required String baselineCommit,
}) => <String, Object?>{
  'schemaVersion': gitEnvironmentProviderStateSchemaVersion,
  'environmentId': environmentId.value,
  'sourcePath': source.scope.path,
  'repositoryPath': source.repository.root.path,
  'sourceRelativePath': source.relativePath,
  'commonGitDirectory': source.repository.commonDirectory.path,
  'worktreePath': worktreePath,
  'branch': branch,
  'baselineCommit': baselineCommit,
};

String _branchName(LocalEnvironment environment) {
  final String title = _slug(environment.task.title, fallback: 'task');
  final String id = _slug(environment.id.value, fallback: 'environment');
  return 'adele-${_truncate(title, 32)}-${_truncate(id, 16)}-'
      '${_stableHash(environment.id.value)}';
}

String _worktreePath(Directory source, LocalEnvironment environment) {
  final String repositoryName = _entityName(source.path);
  final String parentName =
      '.adele-worktrees-'
      '${_truncate(_slug(repositoryName, fallback: 'repository'), 64)}-'
      '${_stableHash(source.path)}';
  final String worktreeName =
      '${_truncate(_slug(environment.task.title, fallback: 'task'), 32)}-'
      '${_truncate(_slug(environment.id.value, fallback: 'environment'), 16)}-'
      '${_stableHash(environment.id.value)}';
  return _childPath(_childPath(source.parent.path, parentName), worktreeName);
}

Future<_GitResourceNames> _allocateGitResourceNames(
  Directory repository,
  LocalEnvironment environment,
) async {
  final String baseBranch = _branchName(environment);
  final String baseWorktreePath = _worktreePath(repository, environment);
  for (int candidate = 1; ; candidate++) {
    final String suffix = candidate == 1 ? '' : '-$candidate';
    final String branch = '$baseBranch$suffix';
    final String worktreePath = '$baseWorktreePath$suffix';
    if (await _branchExists(repository, branch)) continue;
    if (await FileSystemEntity.type(worktreePath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      continue;
    }
    return _GitResourceNames(branch: branch, worktreePath: worktreePath);
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
  Directory repository,
  String worktreePath,
  String branch, {
  required String baselineCommit,
  required bool branchCreated,
  required bool worktreeAddAttempted,
  required bool worktreeAddSucceeded,
}) async {
  if (!branchCreated) return;
  if (worktreeAddAttempted &&
      await _worktreeRegisteredForBranch(repository, worktreePath, branch)) {
    try {
      await _runGit(repository, <String>[
        'worktree',
        'remove',
        '--force',
        worktreePath,
      ]);
    } on ProcessException {
      // Best-effort cleanup after provider-owned establishment failed.
    }
  }
  if (worktreeAddSucceeded) {
    final Directory worktree = Directory(worktreePath);
    try {
      if (await worktree.exists()) await worktree.delete(recursive: true);
    } on FileSystemException {
      // The path is known to have been created by the successful Git add.
    }
  }
  try {
    final ProcessResult branchHead = await _runGit(repository, <String>[
      'show-ref',
      '--hash',
      '--verify',
      'refs/heads/$branch',
    ]);
    if (branchHead.exitCode == 0 &&
        branchHead.stdout.toString().trim() == baselineCommit) {
      await _runGit(repository, <String>['branch', '-D', branch]);
    }
  } on ProcessException {
    // Best-effort cleanup after provider-owned establishment failed.
  }
}

Future<bool> _worktreeRegisteredForBranch(
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
    return false;
  }
  if (result.exitCode != 0) return false;
  String? listedPath;
  for (final String field in result.stdout.toString().split('\u0000')) {
    if (field.isEmpty) {
      listedPath = null;
    } else if (field.startsWith('worktree ')) {
      listedPath = field.substring('worktree '.length);
    } else if (listedPath != null &&
        _sameLocalPath(listedPath, worktreePath) &&
        field == 'branch refs/heads/$branch') {
      return true;
    }
  }
  return false;
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

String _entityName(String path) {
  final List<String> parts = path.split(Platform.pathSeparator);
  return parts.lastWhere(
    (String part) => part.isNotEmpty,
    orElse: () => 'root',
  );
}

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
