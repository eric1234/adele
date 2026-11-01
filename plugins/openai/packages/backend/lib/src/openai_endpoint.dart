import 'dart:io';

Uri validateOpenAiEndpoint(Uri value) {
  final host = value.host;
  final address = InternetAddress.tryParse(host);
  final domain = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  final validHost =
      host.isNotEmpty &&
      (address != null ||
          (domain.length <= 253 &&
              !RegExp(r'^[0-9.]+$').hasMatch(domain) &&
              domain
                  .split('.')
                  .every(
                    (label) =>
                        label.length <= 63 &&
                        RegExp(
                          r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$',
                          caseSensitive: false,
                        ).hasMatch(label),
                  )));
  if (!value.isAbsolute ||
      !value.hasAuthority ||
      (value.scheme != 'http' && value.scheme != 'https') ||
      !validHost ||
      value.authority.contains('@') ||
      value.hasFragment ||
      (value.hasPort && (value.port < 1 || value.port > 65535))) {
    throw ArgumentError('Invalid OpenAI HTTP(S) endpoint.');
  }
  if (value.scheme == 'http' &&
      host.toLowerCase() != 'localhost' &&
      !(address?.isLoopback ?? false)) {
    throw ArgumentError('Plaintext OpenAI endpoints must be loopback.');
  }
  return value;
}
