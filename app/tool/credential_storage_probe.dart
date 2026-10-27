import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:adele_credential_store/adele_credential_store.dart';
import 'package:adele_desktop/core/credential_service.dart';
import 'package:adele_desktop/core/native_credential_storage_adapter.dart';

const _deadline = Duration(seconds: 20);

/// Shared only by the maintained host smoke and its widget test, not plugins.
bool get isCredentialSmokeFixture {
  final env = Platform.environment;
  final root = env['ADELE_CREDENTIAL_STORAGE_FIXTURE'];
  final bus = env['DBUS_SESSION_BUS_ADDRESS'];
  return Platform.isLinux &&
      env['ADELE_CREDENTIAL_STORAGE_SMOKE'] == '1' &&
      root != null &&
      Directory(root).isAbsolute &&
      root.split('/').last.startsWith('adele-credential-smoke-') &&
      Directory(root).existsSync() &&
      bus != null &&
      bus.startsWith('unix:path=$root/run/') &&
      bus != env['ADELE_CREDENTIAL_STORAGE_PARENT_BUS'] &&
      env['XDG_DATA_HOME'] == '$root/data' &&
      env['XDG_RUNTIME_DIR'] == '$root/run' &&
      env['GNOME_KEYRING_CONTROL'] == '$root/control';
}

String disposableCredentialValue() {
  final random = Random.secure();
  return base64Url.encode(List.generate(32, (_) => random.nextInt(256)));
}

void _require(bool condition) {
  if (!condition) throw StateError('Credential smoke assertion failed.');
}

Future<void> _serviceFailure(
  Future<Object?> Function() operation,
  CredentialFailureKind kind,
) async {
  try {
    await operation().timeout(_deadline);
  } on CredentialFailure catch (failure) {
    _require(failure.kind == kind);
    return;
  }
  throw StateError('Expected safe application credential failure.');
}

void _nativeFailure(
  void Function() operation,
  NativeCredentialFailureKind kind,
) {
  try {
    operation();
  } on NativeCredentialFailure catch (failure) {
    _require(failure.kind == kind);
    return;
  }
  throw StateError('Expected safe native credential failure.');
}

Future<void> main(List<String> args) async {
  if (!isCredentialSmokeFixture ||
      args.length != 1 ||
      !['--recover', '--unavailable'].contains(args.single)) {
    stderr.writeln('Refusing probe outside maintained private fixture.');
    exitCode = 2;
    return;
  }
  // `dart run` may leave its hook progress on an unterminated stdout line.
  stdout.writeln();
  final a = CredentialReference.generate();
  final b = CredentialReference.generate();
  var service = createNativeCredentialService();
  var mutationAdmitted = false;
  try {
    _require(NativeCredentialStore.isSupported);
    _require(NativeCredentialStore.maximumBytes == 2560);
    _require(CredentialSecret.maximumBytes == 2560);
    final first = disposableCredentialValue();
    final second = disposableCredentialValue();
    final changed = disposableCredentialValue();

    // These synchronous calls run in this dedicated CLI process, never Flutter's
    // UI isolate. Retrying below in this same isolate catches global init caches.
    for (final operation in <void Function()>[
      () => NativeCredentialStore.contains(a.value),
      () => NativeCredentialStore.read(a.value),
      () => NativeCredentialStore.write(a.value, first),
      () => NativeCredentialStore.delete(a.value),
    ]) {
      _nativeFailure(operation, NativeCredentialFailureKind.unavailable);
    }
    await _serviceFailure(
      () => service.contains(a),
      CredentialFailureKind.unavailable,
    );
    await _serviceFailure(
      () => service.read(a),
      CredentialFailureKind.unavailable,
    );
    if (args.single == '--unavailable') {
      stdout.writeln('PASS_UNAVAILABLE');
      return;
    }
    stdout.writeln('UNAVAILABLE');
    final retry = await stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(_deadline);
    _require(retry == 'retry');
    _require(!NativeCredentialStore.contains(a.value));
    _require(!await service.contains(a).timeout(_deadline));
    stdout.writeln('PASS_RECOVERY');

    _nativeFailure(
      () => NativeCredentialStore.read('../outside'),
      NativeCredentialFailureKind.invalidReference,
    );
    _nativeFailure(
      () => NativeCredentialStore.write(a.value, 'x' * 2561),
      NativeCredentialFailureKind.invalidSecret,
    );
    await _serviceFailure(
      () async => CredentialSecret('\u00e9' * 1281),
      CredentialFailureKind.invalidSecret,
    );
    _require(!await service.contains(a).timeout(_deadline));
    mutationAdmitted = true;
    await service.store(a, CredentialSecret(first)).timeout(_deadline);
    await service.store(b, CredentialSecret(second)).timeout(_deadline);
    _require(await service.contains(a).timeout(_deadline));
    _require(await service.contains(b).timeout(_deadline));
    _require((await service.read(a).timeout(_deadline))?.reveal() == first);
    final bounded = List.generate(
      2560,
      (i) => first.codeUnitAt(i % first.length),
    );
    await service
        .replace(a, CredentialSecret(String.fromCharCodes(bounded)))
        .timeout(_deadline);
    _require(
      (await service.read(a).timeout(_deadline))?.reveal() ==
          String.fromCharCodes(bounded),
    );
    await service.replace(a, CredentialSecret(changed)).timeout(_deadline);
    _require((await service.read(b).timeout(_deadline))?.reveal() == second);
    await service.close().timeout(_deadline);
    service = createNativeCredentialService();
    _require((await service.read(a).timeout(_deadline))?.reveal() == changed);

    // Admit all work without yielding: the production owner must preserve FIFO
    // across its Isolate.run adapter and fence close synchronously while draining.
    final replacing = service.replace(a, CredentialSecret(first));
    final reading = service.read(a);
    final deleting = service.delete(b);
    final closing = service.close();
    final work = Future.wait<Object?>([replacing, reading, deleting, closing]);
    await _serviceFailure(
      () => service.contains(a),
      CredentialFailureKind.closed,
    );
    final results = await work.timeout(_deadline);
    _require((results[1] as CredentialSecret?)?.reveal() == first);
    service = createNativeCredentialService();
    _require(!await service.contains(b).timeout(_deadline));
    _require((await service.read(a).timeout(_deadline))?.reveal() == first);
    await service.delete(a).timeout(_deadline);
    _require(!await service.contains(a).timeout(_deadline));
    stdout.writeln('PASS_SERVICE');
  } on Object {
    stderr.writeln('FAIL production credential probe (details redacted)');
    exitCode = 1;
  } finally {
    try {
      await service.close().timeout(_deadline);
      if (mutationAdmitted) {
        final cleanup = createNativeCredentialService();
        try {
          await (() async {
            for (final reference in [a, b]) {
              await cleanup.read(reference);
              await cleanup.delete(reference);
              _require(!await cleanup.contains(reference));
            }
          })().timeout(_deadline);
          stdout.writeln('PASS_CLEANUP');
        } finally {
          await cleanup.close().timeout(_deadline);
        }
      }
    } on Object {
      stderr.writeln(
        'FAIL production credential probe cleanup (details redacted)',
      );
      exitCode = 1;
    }
  }
}
