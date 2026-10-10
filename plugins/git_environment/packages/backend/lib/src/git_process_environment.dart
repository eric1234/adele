import 'dart:io';

// Git documents repository-local entries through `rev-parse --local-env-vars`.
const _gitEnvironmentVariablesToClear = {
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

/// Placement retains its existing host environment minus Git routing. Read-only
/// inspection excludes credentials/injected Git routing while retaining the
/// ordinary configuration discovery needed for ignore and conversion semantics.
Map<String, String> gitProcessEnvironment({
  Map<String, String>? parentEnvironment,
  bool readOnlyInspection = false,
}) {
  final inherited = parentEnvironment ?? Platform.environment;
  if (!readOnlyInspection) {
    return Map.of(inherited)..removeWhere(
      (name, _) => _gitEnvironmentVariablesToClear.contains(
        Platform.isWindows ? name.toUpperCase() : name,
      ),
    );
  }
  final environment = <String, String>{};
  for (final entry in inherited.entries) {
    final name = Platform.isWindows ? entry.key.toUpperCase() : entry.key;
    if (const {'PATH', 'HOME', 'XDG_CONFIG_HOME'}.contains(name) ||
        (Platform.isWindows &&
            const {
              'SYSTEMROOT',
              'TEMP',
              'TMP',
              'USERPROFILE',
              'HOMEDRIVE',
              'HOMEPATH',
            }.contains(name))) {
      environment[name] = entry.value;
    }
  }
  final separator = Platform.isWindows ? ';' : ':';
  environment['PATH'] = (environment['PATH'] ?? '/usr/bin:/bin')
      .split(separator)
      .where(
        (path) =>
            path.startsWith('/') ||
            (Platform.isWindows && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)),
      )
      .join(separator);
  return environment..addAll({
    'LC_ALL': 'C',
    'LANG': 'C',
    'TERM': 'dumb',
    'GIT_OPTIONAL_LOCKS': '0',
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_NO_REPLACE_OBJECTS': '1',
    'GIT_NO_LAZY_FETCH': '1',
  });
}
