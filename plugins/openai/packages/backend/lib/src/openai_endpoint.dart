import 'dart:io';

const openAiDefaultResponsesEndpoint = 'https://api.openai.com/v1/responses';

/// Queries may select a different API/version or contain routing tokens. Without
/// an explicit catalog route contract, neither forwarding nor dropping them is safe.
Uri? openAiCatalogEndpoint(Uri? responsesEndpoint) {
  final endpoint = validateOpenAiEndpoint(
    responsesEndpoint ?? Uri.parse(openAiDefaultResponsesEndpoint),
  );
  if (endpoint.hasQuery || !endpoint.path.endsWith('/responses')) return null;
  return endpoint.replace(
    path: '${endpoint.path.substring(0, endpoint.path.length - 9)}models',
  );
}

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
