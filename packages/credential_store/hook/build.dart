import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'runtime_audit.dart';

Future<void> main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    if (code.targetOS != OS.current ||
        code.targetArchitecture != Architecture.current) {
      throw UnsupportedError(
        'Credential native cross-compilation is not configured.',
      );
    }
    if (code.linkModePreference == LinkModePreference.static ||
        code.sanitizer != null) {
      throw UnsupportedError(
        'Credentials require unsanitized dynamic linking.',
      );
    }
    final target = switch ((code.targetOS, code.targetArchitecture)) {
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
      (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
      _ => throw UnsupportedError(
        'Unsupported credential native target: ${code.targetOS}/${code.targetArchitecture}',
      ),
    };
    final crate = input.packageRoot.resolve('native/');
    final toolchain = (await File.fromUri(
      crate.resolve('rust-toolchain'),
    ).readAsString()).trim();
    final targetDirectory = input.outputDirectory.resolve('cargo/');
    final cargoArguments = [
      'run',
      toolchain,
      'cargo',
      'build',
      '--locked',
      '--release',
      '--lib',
      '--manifest-path',
      crate.resolve('Cargo.toml').toFilePath(),
      '--target',
      target,
      '--target-dir',
      targetDirectory.toFilePath(),
    ];
    final result = await Process.run(
      'rustup',
      cargoArguments,
      workingDirectory: crate.toFilePath(),
      // The confidentiality policy requires this image's private static Rust
      // runtime. Override ambient flags rather than accepting shared libstd.
      environment: {
        'CARGO_ENCODED_RUSTFLAGS':
            '-C\u001fprefer-dynamic=no\u001f-C\u001fpanic=unwind',
      },
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'rustup',
        cargoArguments,
        'Credential native build failed. Install Rust $toolchain and the $target '
            'target plus the platform linker.\n${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
    final library = File.fromUri(
      targetDirectory.resolve(
        '$target/release/${code.targetOS.dylibFileName(input.packageName)}',
      ),
    );
    if (!await library.exists() || await library.length() == 0) {
      throw StateError('Cargo produced no credential library.');
    }
    if (code.targetOS == OS.linux &&
        code.targetArchitecture == Architecture.x64) {
      Future<String> inspect(String executable, List<String> arguments) async {
        final result = await Process.run(executable, arguments);
        if (result.exitCode != 0) {
          throw StateError(
            'Credential runtime audit requires binutils nm/readelf.',
          );
        }
        return result.stdout as String;
      }

      verifyPrivateRuntime(
        symbols: await inspect('readelf', [
          '--symbols',
          '--wide',
          '--demangle',
          library.path,
        ]),
        dynamicSymbols: await inspect('nm', [
          '-D',
          '--format=posix',
          '--demangle',
          library.path,
        ]),
        dynamicSection: await inspect('readelf', ['--dynamic', library.path]),
      );
    }
    output.dependencies.addAll([
      crate.resolve('Cargo.toml'),
      crate.resolve('Cargo.lock'),
      crate.resolve('rust-toolchain'),
      crate.resolve('src/lib.rs'),
      input.packageRoot.resolve('hook/runtime_audit.dart'),
    ]);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/native.dart',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
  });
}
