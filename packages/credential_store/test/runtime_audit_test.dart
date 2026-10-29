import 'package:test/test.dart';

import '../hook/runtime_audit.dart';

const _symbols = '''
1: 0000 8 OBJECT LOCAL DEFAULT 27 std::panicking::HOOK
2: 0001 8 FUNC LOCAL DEFAULT 14 __rustc::__rust_start_panic
3: 0002 8 FUNC LOCAL DEFAULT 14 __rustc::__rust_panic_cleanup
''';
const _dynamic = '''
adele_credentials_abi_version T 1000 10
adele_credentials_request_v1 T 1010 10
malloc@GLIBC_2.2.5 U
__gmon_start__ w
''';
const _needed = '0x0000000000000001 (NEEDED) Shared library: [libc.so.6]';

void main() {
  test('private runtime and fixed C exports pass', () {
    verifyPrivateRuntime(
      symbols: _symbols,
      dynamicSymbols: _dynamic,
      dynamicSection: _needed,
    );
  });

  test('missing or interposable hook and exception runtime fail closed', () {
    for (final symbols in [
      '',
      _symbols.replaceAll('LOCAL', 'GLOBAL'),
      _symbols.replaceAll('std::panicking::HOOK', 'unrecognized'),
      _symbols.replaceAll('__rust_panic_cleanup', 'unrecognized'),
    ]) {
      expect(
        () => verifyPrivateRuntime(
          symbols: symbols,
          dynamicSymbols: _dynamic,
          dynamicSection: _needed,
        ),
        throwsStateError,
      );
    }
  });

  test('dynamic Rust symbols or extra/missing native exports fail closed', () {
    for (final dynamic in [
      '',
      '$_dynamic\nstd::panicking::set_hook U',
      '$_dynamic\n_RNvNtCs123_3std9panicking4HOOK U',
      '$_dynamic\n__rust_start_panic U',
      '$_dynamic\nextra_backend_selector T 1020 10',
      '$_dynamic\nextra_indirect_function i 1020 10',
      '$_dynamic\nextra_weak_symbol w 1020 10',
    ]) {
      expect(
        () => verifyPrivateRuntime(
          symbols: _symbols,
          dynamicSymbols: dynamic,
          dynamicSection: _needed,
        ),
        throwsStateError,
      );
    }
  });

  test('shared Rust and any unaudited runtime library fail closed', () {
    for (final needed in [
      '',
      '$_needed\n0x1 (NEEDED) Shared library: [libstd-123.so]',
      '$_needed\n0x1 (NEEDED) Shared library: [libother_rust.so]',
      '$_needed\n0x1 (NEEDED) unreadable',
    ]) {
      expect(
        () => verifyPrivateRuntime(
          symbols: _symbols,
          dynamicSymbols: _dynamic,
          dynamicSection: needed,
        ),
        throwsStateError,
      );
    }
  });
}
