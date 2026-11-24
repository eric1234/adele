import 'dart:io';

import '../../../../plugins/openai/packages/backend/bin/openai_model_provider_backend.dart'
    as stock;

// Exercise the documented effort lookup for the actual OpenAI route without
// contacting it. Only the final HTTP destination changes, not the records,
// catalog parser, capabilities, credential reads, or inference implementation.
Future<void> main(List<String> args, Object? bootstrap) async {
  final work = Uri.parse(args[0]);
  final personal = Uri.parse(args[1]);
  for (final origin in [work, personal]) {
    if (origin.scheme != 'http' || origin.host != '127.0.0.1') {
      throw StateError('Expected a loopback fixture.');
    }
  }
  HttpOverrides.global = _Loopback(work, personal);
  await stock.main(['--chatgpt-only'], bootstrap); // No ambient credentials.
}

class _Loopback extends HttpOverrides {
  _Loopback(this.work, this.personal);
  final Uri work;
  final Uri personal;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(
    super.createHttpClient(context)..findProxy = (_) => 'DIRECT',
    work,
    personal,
  );
}

class _Client implements HttpClient {
  _Client(this.delegate, this.work, this.personal);
  final HttpClient delegate;
  final Uri work;
  final Uri personal;

  Uri route(Uri requested, String resource) {
    if (requested == Uri.parse('https://api.openai.com/v1/$resource')) {
      return work.resolve('/work/$resource');
    }
    if (requested == personal.resolve('/personal/$resource')) return requested;
    throw StateError('Unexpected fixture destination.');
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      delegate.getUrl(route(url, 'models'));

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      delegate.postUrl(route(url, 'responses'));

  @override
  void close({bool force = false}) => delegate.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
