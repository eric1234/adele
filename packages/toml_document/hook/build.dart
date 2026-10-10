import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    if (code.targetOS != OS.current ||
        code.targetArchitecture != Architecture.current) {
      throw UnsupportedError(
        'TOML native cross-compilation is not configured.',
      );
    }
    if (code.linkModePreference == LinkModePreference.static ||
        code.sanitizer != null) {
      throw UnsupportedError('TOML requires unsanitized dynamic linking.');
    }
    final target = switch ((code.targetOS, code.targetArchitecture)) {
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
      (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
      _ => throw UnsupportedError(
        'Unsupported TOML native target: ${code.targetOS}/${code.targetArchitecture}',
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
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'rustup',
        cargoArguments,
        'TOML native build failed. Install Rust $toolchain and the $target '
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
      throw StateError('Cargo produced no TOML library: ${library.path}');
    }
    output.dependencies.addAll([
      crate.resolve('Cargo.toml'),
      crate.resolve('Cargo.lock'),
      crate.resolve('rust-toolchain'),
      crate.resolve('src/lib.rs'),
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
