part of 'foreground_process.dart';

final class _ResolvedShell {
  const _ResolvedShell(this.profile, this.invocation, this.arguments);

  final EnvironmentShellProfile profile;
  final String invocation;
  final List<String> arguments;
}

String _newShellGeneration() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
}

void _requireShellSupportedPlatform() {
  if (!Platform.isLinux || Abi.current() != Abi.linuxX64) {
    throw const EnvironmentFailure(
      code: environmentShellUnavailableCode,
      message: 'Shell commands are currently supported on Linux x64.',
      details: <String, Object?>{},
    );
  }
}

Future<_ResolvedShell> _resolveShell(
  EnvironmentId environmentId,
  Directory root,
  Map<String, String> parentEnvironment,
  String generation,
) async {
  _requireShellSupportedPlatform();
  try {
    // Empty is a configured but invalid preference, not permission to substitute.
    final String selection = parentEnvironment['SHELL'] ?? '/bin/sh';
    if (selection.isEmpty ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(selection)) {
      throw const FormatException('The configured shell is malformed.');
    }
    final childEnvironment = _childEnvironment(
      root,
      parentEnvironment: parentEnvironment,
    );
    final invocation = await _resolveExecutable(
      selection,
      root,
      childEnvironment['PATH']!,
      preserveInvocationPath: true,
    );
    final executable = await _requireExecutable(invocation, selection);
    final name = executable.split('/').last;
    final selectedName = invocation.split('/').last;
    if (const {'rbash', 'rzsh', 'rksh', 'rsh'}.contains(selectedName) ||
        selectedName.startsWith('-')) {
      throw const FormatException(
        'Restricted or login shell aliases are unsupported.',
      );
    }
    final String dialect;
    final List<String> arguments;
    switch (name) {
      case 'sh':
      case 'dash':
        dialect = 'posix';
        arguments = const ['-c'];
      case 'bash':
        dialect = 'bash';
        arguments = const ['--noprofile', '--norc', '-c'];
      case 'zsh':
        dialect = 'zsh';
        arguments = const ['-f', '-c'];
      case 'ksh':
      case 'ksh93':
      case 'mksh':
        dialect = 'ksh';
        arguments = const ['-c'];
      default:
        throw const FormatException(
          'The selected shell implementation is unsupported.',
        );
    }
    // Canonicalizing /bin/sh -> bash and invoking bash would change its mode.
    // Keep argv[0] through the observed alias; -c's following argument is not argv[0].
    final launchPath = selectedName == 'sh' ? invocation : executable;
    final actualDialect = selectedName == 'sh' ? 'posix' : dialect;
    await _requireShellExecutableFormat(executable);
    final stat = await FileStat.stat(executable);
    if (stat.type != FileSystemEntityType.file ||
        !_linuxEffectiveAccess.canExecute(executable) ||
        await File(invocation).resolveSymbolicLinks() != executable) {
      throw const FileSystemException(
        'The selected shell changed during discovery.',
      );
    }
    final identity = sha256.convert(
      utf8.encode(
        jsonEncode(<Object?>[
          'git-shell-v1',
          generation,
          environmentId.value,
          root.path,
          parentEnvironment.containsKey('SHELL'),
          selection,
          invocation,
          executable,
          launchPath,
          actualDialect,
          arguments,
          stat.mode,
          stat.size,
          stat.modified.microsecondsSinceEpoch,
          stat.changed.microsecondsSinceEpoch,
        ]),
      ),
    );
    return _ResolvedShell(
      EnvironmentShellProfile(
        profileId: 'git-shell-v1:$identity',
        interpreter: executable,
        dialect: actualDialect,
      ),
      launchPath,
      arguments,
    );
  } on Object catch (error) {
    throw EnvironmentFailure(
      code: environmentShellUnavailableCode,
      message: 'The selected Environment shell is unavailable or unsupported.',
      details: <String, Object?>{
        'environmentId': environmentId.value,
        'reason': error.toString(),
      },
    );
  }
}

// Accept native interpreters only: script wrappers and plain executable text can
// trigger execvp's implicit /bin/sh fallback. This bounded Linux preflight checks
// basic launch prerequisites, not arbitrary program behavior or dynamic dependencies.
Future<void> _requireShellExecutableFormat(String executable) async {
  const invalid = FormatException('The selected shell executable is unusable.');
  final file = await File(executable).open();
  try {
    final header = await file.read(64);
    if (header.length < 64 ||
        header[0] != 0x7f ||
        header[1] != 0x45 ||
        header[2] != 0x4c ||
        header[3] != 0x46 ||
        header[4] != 2 ||
        header[5] != 1 ||
        header[6] != 1) {
      throw invalid;
    }
    final elf = ByteData.sublistView(header);
    final type = elf.getUint16(16, Endian.little);
    final offset = elf.getUint64(32, Endian.little);
    final count = elf.getUint16(56, Endian.little);
    final length = await file.length();
    if ((type != 2 && type != 3) ||
        elf.getUint16(18, Endian.little) != 62 ||
        elf.getUint16(52, Endian.little) != 64 ||
        elf.getUint16(54, Endian.little) != 56 ||
        count == 0 ||
        count > 128 ||
        offset < 64 ||
        offset > length - count * 56) {
      throw invalid;
    }
    await file.setPosition(offset);
    final entries = await file.read(count * 56);
    if (entries.length != count * 56) throw invalid;
    final programs = ByteData.sublistView(entries);
    var loadable = false;
    var foundInterpreter = false;
    for (var index = 0; index < count; index++) {
      final base = index * 56;
      final type = programs.getUint32(base, Endian.little);
      if (type == 1) loadable = true;
      if (type != 3) continue;
      if (foundInterpreter) throw invalid;
      foundInterpreter = true;
      final start = programs.getUint64(base + 8, Endian.little);
      final size = programs.getUint64(base + 32, Endian.little);
      if (size < 2 || size > 4096 || start < 0 || start > length - size) {
        throw invalid;
      }
      await file.setPosition(start);
      final bytes = await file.read(size);
      if (bytes.length != size || bytes.last != 0) throw invalid;
      final interpreter = utf8.decode(bytes.sublist(0, bytes.length - 1));
      if (!interpreter.startsWith('/') ||
          interpreter.contains('\u0000') ||
          !await _isExecutableFile(interpreter)) {
        throw invalid;
      }
    }
    if (!loadable) throw invalid;
  } finally {
    await file.close();
  }
}
