import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'failure.dart';

const maximumCredentialBytes = 2560;
const _asset = 'package:adele_credential_store/src/native.dart';

bool get nativePlatformSupported => Abi.current() == Abi.linuxX64;

@Native<Uint32 Function()>(
  symbol: 'adele_credentials_abi_version',
  assetId: _asset,
)
external int _abiVersion();

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
  Pointer<UintPtr> outputLength,
);

Uint8List encodeReference(String reference) {
  if (reference.length != 38 ||
      !RegExp(r'^cred1_[0-9a-f]{32}$').hasMatch(reference)) {
    throw const NativeCredentialFailure(
      NativeCredentialFailureKind.invalidReference,
    );
  }
  return utf8.encoder.convert(reference);
}

Uint8List encodeSecret(String value) {
  var valid = value.isNotEmpty && value.length <= maximumCredentialBytes;
  for (var i = 0; valid && i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit == 0 || (unit >= 0xdc00 && unit <= 0xdfff)) {
      valid = false;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      i++;
      valid =
          i < value.length &&
          value.codeUnitAt(i) >= 0xdc00 &&
          value.codeUnitAt(i) <= 0xdfff;
    }
  }
  if (!valid) {
    throw const NativeCredentialFailure(
      NativeCredentialFailureKind.invalidSecret,
    );
  }
  final bytes = utf8.encoder.convert(value);
  if (bytes.length > maximumCredentialBytes) {
    bytes.fillRange(0, bytes.length, 0);
    throw const NativeCredentialFailure(
      NativeCredentialFailureKind.invalidSecret,
    );
  }
  return bytes;
}

// Kept separate from FFI so malformed responses and status mappings can be
// tested without selecting a fake backend or contacting a real keyring.
(bool, String?) decodeResponse(
  int operation,
  int status,
  int length,
  Uint8List? output,
) {
  if (length < 0 ||
      length > maximumCredentialBytes ||
      ((operation != 1 || status != 0) && length != 0)) {
    throw const NativeCredentialFailure(NativeCredentialFailureKind.failed);
  }
  if (status == 1 && operation != 2) return (false, null);
  if (status != 0) {
    throw NativeCredentialFailure(switch (status) {
      2 => NativeCredentialFailureKind.unavailable,
      4 => NativeCredentialFailureKind.invalidReference,
      5 => NativeCredentialFailureKind.invalidSecret,
      6 => NativeCredentialFailureKind.corruptData,
      _ => NativeCredentialFailureKind.failed,
    });
  }
  if (operation != 1) return (true, null);
  if (output == null || length == 0 || output.length < length) {
    throw const NativeCredentialFailure(
      NativeCredentialFailureKind.corruptData,
    );
  }
  try {
    final bytes = Uint8List.sublistView(output, 0, length);
    if (bytes.contains(0)) {
      throw const NativeCredentialFailure(
        NativeCredentialFailureKind.corruptData,
      );
    }
    return (true, utf8.decode(bytes, allowMalformed: false));
  } on FormatException {
    throw const NativeCredentialFailure(
      NativeCredentialFailureKind.corruptData,
    );
  }
}

(bool, String?) invokeCredentials(
  int operation,
  String reference,
  String? value,
) {
  Pointer<Uint8> key = nullptr;
  Pointer<Uint8> input = nullptr;
  Pointer<Uint8> output = nullptr;
  Pointer<UintPtr> length = nullptr;
  Uint8List? keyBytes;
  Uint8List? valueBytes;
  try {
    keyBytes = encodeReference(reference);
    if (operation == 2) valueBytes = encodeSecret(value!);
    // Unsupported platforms never resolve or call any native symbol.
    if (!nativePlatformSupported) {
      throw const NativeCredentialFailure(
        NativeCredentialFailureKind.unavailable,
      );
    }
    try {
      if (_abiVersion() != 1) {
        throw const NativeCredentialFailure(
          NativeCredentialFailureKind.unavailable,
        );
      }
    } on ArgumentError {
      throw const NativeCredentialFailure(
        NativeCredentialFailureKind.unavailable,
      );
    }
    key = calloc<Uint8>(keyBytes.length);
    key.asTypedList(keyBytes.length).setAll(0, keyBytes);
    if (valueBytes != null) {
      input = calloc<Uint8>(valueBytes.length);
      input.asTypedList(valueBytes.length).setAll(0, valueBytes);
    }
    if (operation == 1) output = calloc<Uint8>(maximumCredentialBytes);
    length = calloc<UintPtr>();
    final status = _request(
      operation,
      key,
      keyBytes.length,
      input,
      valueBytes?.length ?? 0,
      output,
      operation == 1 ? maximumCredentialBytes : 0,
      length,
    );
    return decodeResponse(
      operation,
      status,
      length.value,
      operation == 1 ? output.asTypedList(maximumCredentialBytes) : null,
    );
  } on NativeCredentialFailure {
    rethrow;
  } on Object {
    throw const NativeCredentialFailure(NativeCredentialFailureKind.failed);
  } finally {
    if (key != nullptr) {
      key.asTypedList(keyBytes!.length).fillRange(0, keyBytes.length, 0);
      calloc.free(key);
    }
    if (input != nullptr) {
      input.asTypedList(valueBytes!.length).fillRange(0, valueBytes.length, 0);
      calloc.free(input);
    }
    if (output != nullptr) {
      output
          .asTypedList(maximumCredentialBytes)
          .fillRange(0, maximumCredentialBytes, 0);
      calloc.free(output);
    }
    if (length != nullptr) {
      length.value = 0;
      calloc.free(length);
    }
    keyBytes?.fillRange(0, keyBytes.length, 0);
    valueBytes?.fillRange(0, valueBytes.length, 0);
  }
}
