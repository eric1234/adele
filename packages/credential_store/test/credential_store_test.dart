import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:adele_credential_store/adele_credential_store.dart';
import 'package:adele_credential_store/src/native.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

const _reference = 'cred1_0123456789abcdef0123456789abcdef';
const _asset = 'package:adele_credential_store/src/native.dart';

@Native<Uint32 Function()>(
  symbol: 'adele_credentials_abi_version',
  assetId: _asset,
)
external int _version();

@Native<
  Uint32 Function(
    Uint32,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Uint8>,
    UintPtr,
    Pointer<UintPtr>,
  )
>(symbol: 'adele_credentials_request_v1', assetId: _asset)
external int _request(
  int operation,
  Pointer<Uint8> reference,
  int referenceLength,
  Pointer<Uint8> secret,
  int secretLength,
  Pointer<Uint8> output,
  int capacity,
  Pointer<UintPtr> length,
);

Matcher _failure(NativeCredentialFailureKind kind) =>
    isA<NativeCredentialFailure>().having((error) => error.kind, 'kind', kind);

void main() {
  test('platform support is explicit and has no keyring initialization', () {
    expect(NativeCredentialStore.isSupported, Abi.current() == Abi.linuxX64);
    expect(NativeCredentialStore.maximumBytes, 2560);
  });

  test('references are exact lowercase ASCII with no diagnostic payload', () {
    expect(encodeReference(_reference).length, 38);
    for (final reference in [
      '',
      '../private',
      '${_reference}a',
      _reference.substring(1),
      _reference.toUpperCase(),
      '$_reference\n',
      'cred1_${'0' * 31}\u0000',
      'cred1_${'0' * 31}\u00e9',
    ]) {
      for (final call in <void Function()>[
        () => NativeCredentialStore.read(reference),
        () => NativeCredentialStore.contains(reference),
        () => NativeCredentialStore.write(reference, 'fixture'),
        () => NativeCredentialStore.delete(reference),
      ]) {
        expect(
          call,
          throwsA(_failure(NativeCredentialFailureKind.invalidReference)),
        );
      }
    }
  });

  test('invalid secrets are rejected before native access', () {
    for (final value in [
      '',
      '\u0000',
      'a\u0000b',
      'x' * 2561,
      '\u{1f512}' * 641,
      String.fromCharCode(0xd800),
      String.fromCharCode(0xdc00),
      String.fromCharCodes([0xd800, 0x61]),
      String.fromCharCodes([0xd800, 0xd800, 0xdc00]),
    ]) {
      expect(
        () => NativeCredentialStore.write(_reference, value),
        throwsA(_failure(NativeCredentialFailureKind.invalidSecret)),
      );
    }
  });

  test('limit counts strict UTF-8 bytes, including exact-bound Unicode', () {
    for (final value in ['x' * 2560, '\u00e9' * 1280, '\u{1f512}' * 640]) {
      final bytes = encodeSecret(value);
      expect(bytes.length, 2560);
      expect(utf8.decode(bytes) == value, isTrue);
      bytes.fillRange(0, bytes.length, 0);
      expect(bytes.every((byte) => byte == 0), isTrue);
    }
    expect(encodeSecret(' '), [32]);
    expect(encodeSecret('\n'), [10]);
  });

  test('all exception strings are fixed and expose no native cause', () {
    for (final kind in NativeCredentialFailureKind.values) {
      expect(
        NativeCredentialFailure(kind).toString(),
        'NativeCredentialFailure(${kind.name})',
      );
    }
  });

  test('only successful absence maps to null or false, never failed write', () {
    for (final operation in [1, 3, 4]) {
      expect(decodeResponse(operation, 1, 0, null), (false, null));
    }
    expect(
      () => decodeResponse(2, 1, 0, null),
      throwsA(_failure(NativeCredentialFailureKind.failed)),
    );
    for (final operation in [2, 3, 4]) {
      expect(decodeResponse(operation, 0, 0, null), (true, null));
    }
  });

  test('fixed error statuses and unknown/ambiguous codes fail closed', () {
    for (final entry in {
      2: NativeCredentialFailureKind.unavailable,
      3: NativeCredentialFailureKind.failed,
      4: NativeCredentialFailureKind.invalidReference,
      5: NativeCredentialFailureKind.invalidSecret,
      6: NativeCredentialFailureKind.corruptData,
      7: NativeCredentialFailureKind.failed,
      8: NativeCredentialFailureKind.failed,
      999: NativeCredentialFailureKind.failed,
    }.entries) {
      expect(
        () => decodeResponse(1, entry.key, 0, null),
        throwsA(_failure(entry.value)),
      );
    }
  });

  test(
    'malformed returned bytes are corrupt, not replacement text or missing',
    () {
      for (final bytes in <List<int>>[
        [],
        [0],
        [0xff],
        [0xc0, 0x80],
        [0xed, 0xa0, 0x80],
        [0xf0, 0x90],
        [97, 0, 98],
      ]) {
        expect(
          () => decodeResponse(1, 0, bytes.length, Uint8List.fromList(bytes)),
          throwsA(_failure(NativeCredentialFailureKind.corruptData)),
        );
      }
    },
  );

  test('response lengths are bounded and checked before reading output', () {
    for (final length in [-1, 2561]) {
      expect(
        () => decodeResponse(1, 0, length, null),
        throwsA(_failure(NativeCredentialFailureKind.failed)),
      );
    }
    for (final status in [1, 2, 3, 4, 5, 6, 999]) {
      expect(
        () => decodeResponse(1, status, 1, null),
        throwsA(_failure(NativeCredentialFailureKind.failed)),
      );
    }
    expect(
      () => decodeResponse(4, 0, 1, null),
      throwsA(_failure(NativeCredentialFailureKind.failed)),
    );
    expect(
      () => decodeResponse(1, 0, 2, Uint8List(1)),
      throwsA(_failure(NativeCredentialFailureKind.corruptData)),
    );
  });

  test('decoded string owns its data after caller clears native output', () {
    final bytes = encodeSecret('\u{1f512}' * 640);
    final result = decodeResponse(1, 0, bytes.length, bytes);
    bytes.fillRange(0, bytes.length, 0);
    expect(result.$1, isTrue);
    expect(result.$2 == '\u{1f512}' * 640, isTrue);
  });

  test(
    'unsupported platforms refuse valid calls without loading native ABI',
    () {
      if (NativeCredentialStore.isSupported) return;
      for (final call in <void Function()>[
        () => NativeCredentialStore.read(_reference),
        () => NativeCredentialStore.contains(_reference),
        () => NativeCredentialStore.write(_reference, 'fixture'),
        () => NativeCredentialStore.delete(_reference),
      ]) {
        expect(
          call,
          throwsA(_failure(NativeCredentialFailureKind.unavailable)),
        );
      }
    },
  );

  test('native ABI validation leaves caller-owned output untouched', () {
    expect(_version(), 1);
    final key = calloc<Uint8>(38);
    final secret = calloc<Uint8>(2);
    final output = calloc<Uint8>(2560);
    final length = calloc<UintPtr>();
    try {
      key.asTypedList(38).setAll(0, encodeReference(_reference));
      secret.asTypedList(2).setAll(0, [0xff, 0]);
      output.asTypedList(2560).fillRange(0, 2560, 0xa5);
      for (var i = 0; i < 3; i++) {
        length.value = 99;
        expect(_request(2, key, 38, secret, 1, nullptr, 0, length), 5);
        expect(length.value, 0);
        length.value = 99;
        expect(_request(1, key, 37, nullptr, 0, output, 2560, length), 4);
        expect(length.value, 0);
        expect(output.asTypedList(2560).every((byte) => byte == 0xa5), isTrue);
        expect(key.asTypedList(38).length, 38);
        expect(secret.asTypedList(2), [0xff, 0]);
      }
    } finally {
      key.asTypedList(38).fillRange(0, 38, 0);
      secret.asTypedList(2).fillRange(0, 2, 0);
      output.asTypedList(2560).fillRange(0, 2560, 0);
      length.value = 0;
      calloc.free(key);
      calloc.free(secret);
      calloc.free(output);
      calloc.free(length);
    }
  });
}
