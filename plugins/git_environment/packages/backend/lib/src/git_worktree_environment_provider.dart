import 'dart:io';

import 'package:adele_capabilities/adele_capabilities.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';

import 'ids.dart';
import 'worktree_environment.dart';

const int gitEnvironmentProviderStateSchemaVersion = 1;

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
    final _GitRepository repository = await _repositoryFor(
      environment.task.project.sourceLocation,
    );
    final String baselineCommit = await _gitOutput(
      repository.root,
      const <String>['rev-parse', 'HEAD'],
      code: 'invalid_git_source',
      message: 'The Git source does not have a baseline commit.',
    );
    final String branch = _branchName(environment);
    final String worktreePath = _worktreePath(repository.root, environment);
    if (await _branchExists(repository.root, branch)) {
      throw _environmentFailure(
        'worktree_branch_exists',
        'The Task worktree branch already exists.',
        environmentId: environment.id,
        details: <String, Object?>{'branch': branch},
      );
    }
    if (await FileSystemEntity.type(worktreePath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw _environmentFailure(
        'worktree_exists',
        'The Task worktree path already exists.',
        environmentId: environment.id,
        details: <String, Object?>{'worktreePath': worktreePath},
      );
    }
    bool worktreeCreated = false;
    try {
      await Directory(worktreePath).parent.create(recursive: true);
      await _gitOutput(
        repository.root,
        <String>['worktree', 'add', '-b', branch, worktreePath, baselineCommit],
        code: 'worktree_establishment_failed',
        message: 'Git could not create the Task worktree.',
      );
      worktreeCreated = true;
      final WorktreeEnvironment live = WorktreeEnvironment(
        Directory(worktreePath),
      );
      liveObjects.bind(environment.id, live);
      return EnvironmentProviderResult(
        providerState: _providerState(
          environmentId: environment.id,
          repository: repository,
          worktreePath: live.root.path,
          branch: branch,
          baselineCommit: baselineCommit,
        ),
      );
    } on Object catch (error) {
      await _cleanupFailedEstablishment(
        repository.root,
        worktreePath,
        branch,
        deleteBranch: worktreeCreated,
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
    final _GitRepository repository = await _repositoryFor(
      environment.task.project.sourceLocation,
    );
    if (repository.root.path != state.sourcePath ||
        repository.commonDirectory.path != state.commonGitDirectory) {
      throw _environmentFailure(
        'restore_source_mismatch',
        'The retained worktree belongs to another Git source.',
        environmentId: environment.id,
      );
    }
    final WorktreeEnvironment live;
    try {
      live = WorktreeEnvironment(Directory(state.worktreePath));
    } on ArgumentError catch (error) {
      throw _environmentFailure(
        'restore_worktree_missing',
        'The retained Git worktree is unavailable.',
        environmentId: environment.id,
        details: <String, Object?>{'reason': error.message.toString()},
      );
    }
    final _GitRepository worktree = await _inspectRepository(
      live.root,
      failureCode: 'restore_worktree_invalid',
      failureMessage: 'The retained path is not a usable Git worktree.',
    );
    if (worktree.root.path != live.root.path ||
        worktree.commonDirectory.path != repository.commonDirectory.path) {
      throw _environmentFailure(
        'restore_worktree_mismatch',
        'The retained path is not the expected linked Git worktree.',
        environmentId: environment.id,
      );
    }
    await _requireLinkedWorktree(
      environment.id,
      live.root,
      repository.commonDirectory,
    );
    final String branch = await _gitOutput(
      live.root,
      const <String>['symbolic-ref', '--quiet', '--short', 'HEAD'],
      code: 'restore_branch_invalid',
      message: 'The retained Git worktree is not on its expected branch.',
    );
    if (branch != state.branch) {
      throw _environmentFailure(
        'restore_branch_mismatch',
        'The retained Git worktree branch changed unexpectedly.',
        environmentId: environment.id,
        details: <String, Object?>{
          'expectedBranch': state.branch,
          'actualBranch': branch,
        },
      );
    }
    final String resolvedBaseline = await _gitOutput(
      live.root,
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
    liveObjects.bind(environment.id, live);
    return EnvironmentProviderResult(
      providerState: _providerState(
        environmentId: environment.id,
        repository: repository,
        worktreePath: live.root.path,
        branch: branch,
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

final class _GitProviderState {
  const _GitProviderState({
    required this.sourcePath,
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
      commonGitDirectory: requireString('commonGitDirectory'),
      worktreePath: requireString('worktreePath'),
      branch: requireString('branch'),
      baselineCommit: requireString('baselineCommit'),
    );
  }

  final String sourcePath;
  final String commonGitDirectory;
  final String worktreePath;
  final String branch;
  final String baselineCommit;
}

Future<_GitRepository> _repositoryFor(Uri sourceLocation) async {
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
  return _inspectRepository(
    source,
    failureCode: 'invalid_git_source',
    failureMessage: 'The local Project source is not a usable Git worktree.',
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
        : '${root.path}${Platform.pathSeparator}$commonPath',
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
  required _GitRepository repository,
  required String worktreePath,
  required String branch,
  required String baselineCommit,
}) => <String, Object?>{
  'schemaVersion': gitEnvironmentProviderStateSchemaVersion,
  'environmentId': environmentId.value,
  'sourcePath': repository.root.path,
  'commonGitDirectory': repository.commonDirectory.path,
  'worktreePath': worktreePath,
  'branch': branch,
  'baselineCommit': baselineCommit,
};

String _branchName(LocalEnvironment environment) {
  final String title = _slug(environment.task.title, fallback: 'task');
  final String id = _slug(environment.id.value, fallback: 'environment');
  return 'adele/${_truncate(title, 32)}-${_truncate(id, 16)}-'
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
  return '${source.parent.path}${Platform.pathSeparator}$parentName'
      '${Platform.pathSeparator}$worktreeName';
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
    result = await Process.run('git', <String>[
      '-C',
      workingDirectory.path,
      ...arguments,
    ]);
  } on ProcessException catch (error) {
    throw EnvironmentFailure(
      code: 'git_unavailable',
      message: 'The Git executable is unavailable.',
      details: <String, Object?>{'reason': error.message},
    );
  }
  final String stdoutText = result.stdout.toString().trim();
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

Future<bool> _branchExists(Directory repository, String branch) async {
  final ProcessResult result;
  try {
    result = await Process.run('git', <String>[
      '-C',
      repository.path,
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
  required bool deleteBranch,
}) async {
  if (!deleteBranch) return;
  try {
    await Process.run('git', <String>[
      '-C',
      repository.path,
      'worktree',
      'remove',
      '--force',
      worktreePath,
    ]);
  } on ProcessException {
    // Best-effort cleanup after provider-owned establishment failed.
  }
  try {
    await Process.run('git', <String>[
      '-C',
      repository.path,
      'branch',
      '-D',
      branch,
    ]);
  } on ProcessException {
    // Best-effort cleanup after provider-owned establishment failed.
  }
  final Directory worktree = Directory(worktreePath);
  try {
    if (await worktree.exists()) await worktree.delete(recursive: true);
  } on FileSystemException {
    // Git resources remain durable; failed-establishment cleanup is local only.
  }
}

bool _isAbsolutePath(String path) =>
    path.startsWith(Platform.pathSeparator) ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

String _entityName(String path) {
  final List<String> parts = path.split(Platform.pathSeparator);
  return parts.lastWhere((String part) => part.isNotEmpty);
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
