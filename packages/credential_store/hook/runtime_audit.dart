/// Fail closed unless the Linux x64 image owns a hidden, static Rust runtime.
/// No diagnostics contain native requests, returned secrets, or panic payloads.
void verifyPrivateRuntime({
  required String symbols,
  required String dynamicSymbols,
  required String dynamicSection,
}) {
  const requiredPrivate = [
    'std::panicking::HOOK',
    '__rust_start_panic',
    '__rust_panic_cleanup',
  ];
  for (final name in requiredPrivate) {
    final matches = symbols.split('\n').where((line) => line.contains(name));
    if (matches.isEmpty ||
        matches.any((line) => !RegExp(r'\bLOCAL\b').hasMatch(line))) {
      throw StateError('Credential runtime symbols are not proven private.');
    }
  }
  const exports = {
    'adele_credentials_abi_version',
    'adele_credentials_request_v1',
  };
  final found = <String>{};
  for (final line in dynamicSymbols.split('\n')) {
    if (line.trim().isEmpty) continue;
    // Rust names must not be imported OR exported. This also rejects mangled
    // names if the binutils demangler does not recognize the compiler format.
    if (line.contains('::') ||
        RegExp(
          r'(^|\s)(_R|_ZN|__rust|rust_begin_unwind|rust_eh_personality)',
        ).hasMatch(line)) {
      throw StateError('Credential runtime has shared Rust symbols.');
    }
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2) {
      throw StateError('Credential runtime symbol audit is unreadable.');
    }
    if (fields[1] == 'U' ||
        (fields.length == 2 && (fields[1] == 'w' || fields[1] == 'v'))) {
      continue;
    }
    if (fields[1] != 'T' || !exports.contains(fields[0])) {
      throw StateError('Credential runtime has an unexpected native export.');
    }
    found.add(fields[0]);
  }
  if (found.length != exports.length) {
    throw StateError('Credential runtime is missing its native ABI.');
  }
  const systemLibraries = {
    'libgcc_s.so.1',
    'libm.so.6',
    'libc.so.6',
    'ld-linux-x86-64.so.2',
    'libpthread.so.0',
    'librt.so.1',
    'libdl.so.2',
  };
  final needed = dynamicSection
      .split('\n')
      .where((line) => line.contains('(NEEDED)'));
  if (needed.isEmpty ||
      needed.any((line) {
        final name = RegExp(r'\[([^\]]+)\]').firstMatch(line)?.group(1);
        return !systemLibraries.contains(name);
      })) {
    throw StateError('Credential runtime has unaudited shared dependencies.');
  }
}
