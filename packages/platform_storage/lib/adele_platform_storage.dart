import 'package:path/path.dart' as p;

/// Distinct absolute paths for ADELE's host-owned global storage domains.
///
/// Resolution is purely lexical: it neither inspects nor creates directories,
/// resolves filesystem aliases, nor checks permissions. These paths do not
/// provide persistence, configuration precedence, or plugin storage authority.
final class PlatformStorageRoots {
  /// Supplies explicit roots without consulting the environment or filesystem.
  ///
  /// Paths are normalized using [operatingSystem]'s syntax. Invalid paths or
  /// duplicate normalized roots throw [ArgumentError]. Unsupported operating
  /// systems throw [UnsupportedError], as in [PlatformStorageRoots.resolve].
  factory PlatformStorageRoots({
    required String operatingSystem,
    required String configurationRoot,
    required String localStateRoot,
    required String localDataRoot,
    required String cacheRoot,
  }) {
    final paths = _pathContext(operatingSystem);
    final roots = <String, String>{
      'configurationRoot': configurationRoot,
      'localStateRoot': localStateRoot,
      'localDataRoot': localDataRoot,
      'cacheRoot': cacheRoot,
    }.map((name, value) => MapEntry(name, _absolutePath(value, name, paths)));
    final entries = roots.entries.toList();
    for (var index = 0; index < entries.length; index++) {
      for (var other = 0; other < index; other++) {
        if (paths.equals(entries[index].value, entries[other].value)) {
          throw ArgumentError.value(
            entries[index].value,
            entries[index].key,
            'Storage roots must be distinct from ${entries[other].key}.',
          );
        }
      }
    }
    return PlatformStorageRoots._(
      roots['configurationRoot']!,
      roots['localStateRoot']!,
      roots['localDataRoot']!,
      roots['cacheRoot']!,
    );
  }

  /// Resolves Linux, macOS, or Windows roots from injected platform inputs.
  ///
  /// [operatingSystem] accepts `linux`, `macos`, or `windows`, matching Dart's
  /// platform names. No ambient platform or environment values are read.
  /// [homeDirectory] overrides `HOME` on Linux/macOS; it is unused on Windows.
  ///
  /// Linux ignores invalid XDG overrides and uses the standard home-relative
  /// defaults. Each base receives `adele/config`, `adele/state`, `adele/data`,
  /// or `adele/cache`, keeping domains distinct even when bases are equal.
  /// A home directory is required only when a default is needed.
  ///
  /// macOS uses `Library/Application Support/ADELE/{config,state,data}` and
  /// `Library/Caches/ADELE` below home. Windows requires fully qualified
  /// `APPDATA` and `LOCALAPPDATA`, using `ADELE/config` under the former and
  /// `ADELE/{state,data,cache}` under the latter. Drive-relative and root-relative
  /// Windows paths are rejected; complete UNC server/share paths are supported.
  ///
  /// Missing or invalid required inputs throw [ArgumentError] naming the input.
  /// Unsupported operating systems throw [UnsupportedError].
  factory PlatformStorageRoots.resolve({
    required String operatingSystem,
    required Map<String, String> environment,
    String? homeDirectory,
  }) {
    final paths = _pathContext(operatingSystem);
    String home() => _absolutePath(
      homeDirectory ?? environment['HOME'],
      homeDirectory == null ? 'HOME' : 'homeDirectory',
      paths,
    );

    switch (operatingSystem) {
      case 'linux':
        String xdgBase(String key, String fallback) {
          final value = environment[key];
          return value != null && _isAbsolute(value, paths)
              ? paths.normalize(value)
              : paths.join(home(), fallback);
        }

        return PlatformStorageRoots(
          operatingSystem: operatingSystem,
          configurationRoot: paths.join(
            xdgBase('XDG_CONFIG_HOME', '.config'),
            'adele',
            'config',
          ),
          localStateRoot: paths.join(
            xdgBase('XDG_STATE_HOME', '.local/state'),
            'adele',
            'state',
          ),
          localDataRoot: paths.join(
            xdgBase('XDG_DATA_HOME', '.local/share'),
            'adele',
            'data',
          ),
          cacheRoot: paths.join(
            xdgBase('XDG_CACHE_HOME', '.cache'),
            'adele',
            'cache',
          ),
        );
      case 'macos':
        final homePath = home();
        final support = paths.join(homePath, 'Library', 'Application Support');
        return PlatformStorageRoots(
          operatingSystem: operatingSystem,
          configurationRoot: paths.join(support, 'ADELE', 'config'),
          localStateRoot: paths.join(support, 'ADELE', 'state'),
          localDataRoot: paths.join(support, 'ADELE', 'data'),
          cacheRoot: paths.join(homePath, 'Library', 'Caches', 'ADELE'),
        );
      case 'windows':
        final roaming = _absolutePath(environment['APPDATA'], 'APPDATA', paths);
        final local = _absolutePath(
          environment['LOCALAPPDATA'],
          'LOCALAPPDATA',
          paths,
        );
        return PlatformStorageRoots(
          operatingSystem: operatingSystem,
          configurationRoot: paths.join(roaming, 'ADELE', 'config'),
          localStateRoot: paths.join(local, 'ADELE', 'state'),
          localDataRoot: paths.join(local, 'ADELE', 'data'),
          cacheRoot: paths.join(local, 'ADELE', 'cache'),
        );
      default:
        throw UnsupportedError(
          'Unsupported operating system: $operatingSystem',
        );
    }
  }

  const PlatformStorageRoots._(
    this.configurationRoot,
    this.localStateRoot,
    this.localDataRoot,
    this.cacheRoot,
  );

  final String configurationRoot;
  final String localStateRoot;
  final String localDataRoot;
  final String cacheRoot;
}

p.Context _pathContext(String operatingSystem) => switch (operatingSystem) {
  'linux' || 'macos' => p.posix,
  'windows' => p.windows,
  _ => throw UnsupportedError('Unsupported operating system: $operatingSystem'),
};

String _absolutePath(String? value, String name, p.Context paths) {
  if (value == null || !_isAbsolute(value, paths)) {
    throw ArgumentError.value(
      value,
      name,
      paths.style == p.Style.windows
          ? 'Expected a fully qualified drive or UNC server/share directory path.'
          : 'Expected a non-empty absolute directory path.',
    );
  }
  return paths.normalize(
    paths.style == p.Style.windows ? value.replaceAll('/', r'\') : value,
  );
}

bool _isAbsolute(String value, p.Context paths) {
  if (value.isEmpty || value.contains('\x00')) return false;
  if (paths.style != p.Style.windows) return paths.isAbsolute(value);

  final windowsPath = value.replaceAll('/', r'\');
  if (!paths.isAbsolute(windowsPath) || paths.isRootRelative(windowsPath)) {
    return false;
  }
  if (!windowsPath.startsWith(r'\\')) return true;

  // package:path treats incomplete UNC prefixes as absolute, too.
  final parts = windowsPath.substring(2).split(r'\');
  return parts.length >= 2 &&
      parts
          .take(2)
          .every(
            (part) =>
                part.isNotEmpty && part != '.' && part != '..' && part != '?',
          );
}
