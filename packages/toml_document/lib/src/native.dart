import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../adele_toml_document.dart';

const _asset = 'package:adele_toml_document/src/native.dart';

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(
  symbol: 'adele_toml_request',
  assetId: _asset,
)
external Pointer<Utf8> _request(Pointer<Utf8> request);

@Native<Void Function(Pointer<Utf8>)>(
  symbol: 'adele_toml_free',
  assetId: _asset,
)
external void _free(Pointer<Utf8> response);

Map<String, Object?> invokeToml(Map<String, Object?> request) {
  final input = jsonEncode(request).toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  String response;
  try {
    try {
      output = _request(input);
    } on ArgumentError catch (error) {
      throw TomlNativeException(
        'Cannot load the toml_edit native asset. Run through the supported '
        'Dart/Flutter build hooks with the pinned Rust toolchain. $error',
      );
    }
    if (output == nullptr) {
      throw const TomlNativeException('Native TOML operation returned null.');
    }
    response = output.toDartString();
  } finally {
    // Each allocator releases only its own memory, including on failures.
    malloc.free(input);
    if (output != nullptr) _free(output);
  }
  final result = (jsonDecode(response) as Map<String, dynamic>)
      .cast<String, Object?>();
  if (result['error'] case final Map<String, dynamic> error) {
    throw TomlException(
      TomlFailureKind.values.byName(error['kind'] as String),
      error['message'] as String,
    );
  }
  return result;
}
