import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:search_tools_backend/search_tools_backend.dart';
import 'package:search_tools_plugin/search_tools_plugin.dart';
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.close());

  test(
    'materializes exactly the semantic descriptor with one stable route',
    () async {
      final local = const SearchExecutable.unbound().registration;
      fixture.host.close();
      for (final token in <String?>[null, 'unused-materialization-token']) {
        final descriptor = (await fixture.client.materialize(
          'session',
          token,
        )).single;
        expect(descriptor.toolId, 'dev.adele.plugin.search-tools.search');
        expect(descriptor.routeId, descriptor.toolId);
        expect(descriptor.toolDescription, local.definition.description);
        expect(descriptor.modelAlias, 'search');
        expect(descriptor.modelDescription, local.modelDefinition.description);
        expect(
          descriptor.argumentsSchema,
          local.modelDefinition.argumentsSchema,
        );
      }
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'validation uses the actual semantic validator without host authority',
    () async {
      fixture.host.close();
      const semantic = SearchExecutable.unbound();
      for (final proposed in <Map<String, Object?>>[
        {},
        {'query': ''},
        {'query': 1},
        {'query': 'x', 'extra': true},
        {'query': 'x', 'path': null},
        {'query': 'x', 'path': 1},
        {'query': 'x' * 257},
        for (final separator in ['\n', '\r', '\u0000', '\u2028', '\u2029'])
          {'query': 'a${separator}b'},
        for (final path in [
          '/absolute',
          'a/../b',
          'a\u0000b',
          'bad\uD800',
          '\uDC00',
        ])
          {'query': 'x', 'path': path},
      ]) {
        late String message;
        try {
          semantic.validateAndNormalize(proposed);
          fail('Semantic validation unexpectedly succeeded.');
        } on FormatException catch (error) {
          message = error.message;
        }
        await expectLater(
          fixture.client.validateAndNormalize(searchToolId.value, proposed),
          throwsA(
            isA<RemoteToolArgumentValidationFailure>()
                .having((error) => error.code, 'code', 'invalid_arguments')
                .having((error) => error.message, 'message', message)
                .having((error) => error.details, 'details', isEmpty),
          ),
        );
        expect(fixture.channel.response!['error'], {
          'code': 'invalid_arguments',
          'message': message,
          'details': <String, Object?>{},
          'declaredFailureType': remoteToolArgumentValidationFailureTypeId,
        });
      }
      for (final proposed in <Map<String, Object?>>[
        {'query': r'a.*[literal]'},
        {'query': '  ', 'path': './src//./'},
        {'query': 'x' * 256, 'path': 'paired-\uD83D\uDE00/./file'},
        {'query': 'x', 'path': r'odd\name'},
      ]) {
        expect(
          (await fixture.client.validateAndNormalize(
            searchToolId.value,
            proposed,
          )).snapshot,
          semantic.validateAndNormalize(proposed).snapshot,
        );
      }
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'route and protocol failures are not semantic argument rejection',
    () async {
      for (final route in ['search', 'unknown', '']) {
        await expectLater(
          fixture.client.validateAndNormalize(route, {}),
          throwsA(
            isA<AdeleRemoteFailure>()
                .having((error) => error.declaredFailureType, 'type', isNull)
                .having((error) => error.code, 'code', 'internal_error'),
          ),
        );
        await expectLater(
          fixture.client.describe(
            route,
            _arguments(),
            'session',
            'run',
            'token',
          ),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        await expectLater(
          fixture.backend.execute(
            route,
            _arguments(),
            'session',
            'run',
            'token',
          ),
          emitsError(isArgumentError),
        );
      }
      for (final payload in <Map<String, Object?>>[
        {'routeId': searchToolId.value, 'proposedArguments': 'not a map'},
        {
          'routeId': searchToolId.value,
          'proposedArguments': {},
          'hostInvocationContext': 'forbidden',
        },
        {'proposedArguments': {}},
      ]) {
        final response = await fixture.forward.dispatch({
          'kind': 'request',
          'requestId': 42,
          'method': remoteModelToolServiceValidateAndNormalizeId,
          'payload': payload,
        });
        final error = response['error']! as Map;
        expect(error['code'], 'invalid_request');
        expect(error.containsKey('declaredFailureType'), isFalse);
      }
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'describe and execute obtain fresh authority only from each bound client',
    () async {
      final first = fixture.bind(
        'description-one',
        environmentId: 'environment-one',
      );
      final second = fixture.bind(
        'description-two',
        environmentId: 'environment-two',
      );
      final execution = fixture.bind(
        'execution',
        environmentId: 'environment-three',
      )..files['src/file.txt'] = 'Needle\nneedle needle';
      final descriptor = (await fixture.client.materialize(
        'ignored-session',
        'expired',
      )).single;
      final arguments = await fixture.client.validateAndNormalize(
        descriptor.routeId,
        {'query': 'needle', 'path': './src//file.txt'},
      );
      for (final token in ['description-one', 'description-two']) {
        final effect = await fixture.client.describe(
          descriptor.routeId,
          arguments,
          'session',
          'unrelated-run',
          token,
        );
        expect(effect.effects, [RemoteToolEffect.sourceRead]);
        expect(effect.uncertainty, RemoteEffectUncertainty.none);
        expect(
          effect.targetUris.single.toString(),
          'adele-environment:/environment-${token == 'description-one' ? 'one' : 'two'}/src/file.txt',
        );
        expect(
          effect.summary,
          'Search the authorized Environment scope "src/file.txt".',
        );
      }
      final outcome = await fixture.execute(arguments, token: 'execution');
      expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
      expect(outcome.hostData['environmentId'], 'environment-three');
      expect(outcome.hostData['matches'], [
        {
          'relativePath': 'src/file.txt',
          'lineNumber': 2,
          'snippet': 'needle needle',
        },
      ]);
      expect(first.reads, isEmpty);
      expect(second.reads, isEmpty);
      expect(execution.reads, ['directory:src/file.txt', 'file:src/file.txt']);
      expect(
        fixture.requests.map((request) => request['hostInvocationContext']),
        [
          'description-one',
          'description-two',
          'execution',
          'execution',
          'execution',
        ],
      );
      expect(fixture.requests.map((request) => request['payload']), [
        <String, Object?>{},
        <String, Object?>{},
        <String, Object?>{},
        {'relativePath': 'src/file.txt'},
        {'relativePath': 'src/file.txt'},
      ]);
      expect(
        fixture.requests.every(
          (request) =>
              request['serviceId'] == authorizedEnvironmentReadServiceId,
        ),
        isTrue,
      );
    },
  );

  test(
    'semantic Session IDs cannot select or replace host authority',
    () async {
      final files = fixture.bind('bound', environmentId: 'actual-environment');
      await expectLater(
        fixture.client.describe(
          searchToolId.value,
          _arguments(),
          'forged-session',
          'run',
          'bound',
        ),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      final event = await fixture.backend
          .execute(
            searchToolId.value,
            _arguments(),
            'forged-session',
            'run',
            'bound',
          )
          .single;
      expect(event.kind, RemoteToolExecutionEventKind.terminal);
      expect(event.outcome!.failureKind, RemoteToolFailureKind.infrastructure);
      expect(
        event.outcome!.effectCertainty,
        RemoteEffectCertainty.knownNotOccurred,
      );
      expect(event.outcome!.hostData['environmentId'], 'actual-environment');
      expect(event.outcome!.toLocal().cause, isNull);
      expect(files.reads, isEmpty);
      expect(fixture.requests.map((request) => request['method']), [
        authorizedEnvironmentReadServiceAuthorityId,
        authorizedEnvironmentReadServiceAuthorityId,
      ]);
      expect(
        fixture.requests.every(
          (request) => (request['payload']! as Map).isEmpty,
        ),
        isTrue,
      );
    },
  );

  test(
    'missing and expired operation contexts never reuse previous authority',
    () async {
      final files = fixture.bind('live');
      await fixture.client.describe(
        searchToolId.value,
        _arguments(),
        'session',
        'run',
        'live',
      );
      fixture.services.remove('live');
      for (final token in <String?>[null, '', 'live']) {
        await expectLater(
          fixture.client.describe(
            searchToolId.value,
            _arguments(),
            'session',
            'run',
            token,
          ),
          throwsA(
            isA<AdeleRemoteFailure>().having(
              (error) => error.declaredFailureType,
              'type',
              isNull,
            ),
          ),
        );
        await expectLater(
          fixture.backend.execute(
            searchToolId.value,
            _arguments(),
            'session',
            'run',
            token,
          ),
          emitsError(isNot(isA<RemoteToolArgumentValidationFailure>())),
        );
      }
      expect(files.reads, isEmpty);
      expect(fixture.requests, hasLength(3));
      expect(
        fixture.requests.every(
          (request) =>
              request['method'] == authorizedEnvironmentReadServiceAuthorityId,
        ),
        isTrue,
      );
    },
  );

  test(
    'recursive generated reads preserve Search ordering, exclusions and diagnostics',
    () async {
      final files = fixture.bind('execute')
        ..directories[''] = [
          _entry('z', EnvironmentDirectoryEntryKind.directory),
          _entry('b.txt'),
          _entry('BUILD', EnvironmentDirectoryEntryKind.directory),
          _entry('a.txt'),
        ]
        ..directories['z'] = [_entry('z/c.txt')]
        ..files.addAll({
          'a.txt': 'needle twice needle',
          'z/c.txt': 'Needle\nneedle',
        })
        ..fileFailures['b.txt'] = const EnvironmentFailure(
          code: 'denied',
          message: 'Denied.',
          details: {},
        );
      final outcome = await fixture.execute(_arguments(), token: 'execute');
      expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, RemoteEffectCertainty.knownOccurred);
      expect(outcome.hostData['matches'], [
        {
          'relativePath': 'a.txt',
          'lineNumber': 1,
          'snippet': 'needle twice needle',
        },
        {'relativePath': 'z/c.txt', 'lineNumber': 2, 'snippet': 'needle'},
      ]);
      expect(outcome.hostData['incomplete'], isTrue);
      expect(outcome.hostData['truncated'], isFalse);
      expect(outcome.hostData['failedFileReads'], 1);
      expect(outcome.modelContent, contains('Traversal completed'));
      expect(files.reads, [
        'directory:',
        'file:a.txt',
        'file:b.txt',
        'directory:z',
        'file:z/c.txt',
      ]);
    },
  );

  test(
    'declared read failure remains a semantic domain outcome without a cause',
    () async {
      final files = fixture.bind('execute')
        ..directoryFailures['src'] = const EnvironmentFailure(
          code: 'denied',
          message: 'Exact failure.',
          details: {'scope': 'src'},
        );
      final outcome = await fixture.execute(
        _arguments(path: 'src'),
        token: 'execute',
      );
      expect(outcome.failureKind, RemoteToolFailureKind.domain);
      expect(outcome.effectCertainty, RemoteEffectCertainty.uncertain);
      expect(outcome.hostData['code'], 'denied');
      expect(outcome.hostData['details'], {'scope': 'src'});
      expect(outcome.hostDiagnostic, 'Exact failure.');
      expect(outcome.toLocal().cause, isNull);
      expect(files.reads, ['directory:src']);
    },
  );

  test(
    'undeclared read errors are infrastructure failures, not file probes',
    () async {
      final files = fixture.bind('execute')
        ..directoryFailures['src'] = const FormatException('private detail');
      final outcome = await fixture.execute(
        _arguments(path: 'src'),
        token: 'execute',
      );
      expect(outcome.failureKind, RemoteToolFailureKind.infrastructure);
      expect(outcome.hostData.containsKey('code'), isFalse);
      expect(outcome.hostDiagnostic, isNot(contains('private detail')));
      expect(outcome.toLocal().cause, isNull);
      expect(files.reads, ['directory:src']);
    },
  );

  test(
    'excluded scopes and match limits still belong to the semantic executable',
    () async {
      final files = fixture.bind('execute')
        ..files['many.txt'] = List.filled(101, 'needle').join('\n');
      final excluded = await fixture.execute(
        _arguments(path: 'src/BUILD'),
        token: 'execute',
      );
      expect(excluded.failureKind, RemoteToolFailureKind.domain);
      expect(excluded.effectCertainty, RemoteEffectCertainty.knownNotOccurred);
      expect(excluded.hostDiagnostic, 'excluded_scope');
      expect(files.reads, isEmpty);
      final bounded = await fixture.execute(
        _arguments(path: 'many.txt'),
        token: 'execute',
      );
      expect(bounded.hostData['matches'], hasLength(100));
      expect(bounded.hostData['truncated'], isTrue);
      expect(bounded.hostData['stopReason'], 'max_matches');
    },
  );
}

RemoteCanonicalToolArguments _arguments({String path = ''}) =>
    RemoteCanonicalToolArguments.fromLocal(
      const SearchExecutable.unbound().validateAndNormalize({
        'query': 'needle',
        'path': path,
      }),
    );

EnvironmentDirectoryEntry _entry(
  String path, [
  EnvironmentDirectoryEntryKind kind = EnvironmentDirectoryEntryKind.file,
]) => EnvironmentDirectoryEntry(
  name: path.split('/').last,
  relativePath: path,
  kind: kind,
);

final class _Fixture {
  final requests = <Map<String, Object?>>[];
  final services = <String, AuthorizedEnvironmentReadServiceDispatcher>{};
  final dispatchers = <AuthorizedEnvironmentReadServiceDispatcher>[];
  late final host = AdeleHostRequestMultiplexer(
    send: (request) {
      requests.add(request);
      unawaited(_respond(request));
    },
  );
  late final backend = SearchToolsBackend(host);
  late final forward = RemoteModelToolServiceDispatcher(backend);
  late final channel = _Channel(forward);
  late final client = RemoteModelToolServiceClient(channel);

  _Files bind(String token, {String environmentId = 'environment'}) {
    final files = _Files(environmentId);
    final dispatcher = AuthorizedEnvironmentReadServiceDispatcher(files);
    services[token] = dispatcher;
    dispatchers.add(dispatcher);
    return files;
  }

  Future<RemoteToolOutcome> execute(
    RemoteCanonicalToolArguments arguments, {
    required String token,
  }) async {
    final event = await backend
        .execute(searchToolId.value, arguments, 'session', 'run', token)
        .single;
    expect(event.kind, RemoteToolExecutionEventKind.terminal);
    expect(event.progress, isNull);
    return event.outcome!;
  }

  Future<void> _respond(Map<String, Object?> request) async {
    final dispatcher = services[request['hostInvocationContext']];
    final response = dispatcher == null
        ? <String, Object?>{
            'ok': false,
            'error': {
              'code': 'host_invocation_unavailable',
              'message': 'Operation ended.',
            },
          }
        : await dispatcher.dispatch({
            'kind': 'request',
            'requestId': request['requestId'],
            'method': request['method'],
            'payload': request['payload'],
          });
    host.handleResponse({
      'kind': 'hostResponse',
      'requestId': request['requestId'],
      'ok': response['ok'],
      if (response['ok'] == true)
        'payload': response['payload']
      else
        'error': response['error'],
    });
  }

  Future<void> close() async {
    host.close();
    await forward.close();
    for (final dispatcher in dispatchers) {
      await dispatcher.close();
    }
  }
}

final class _Files implements AuthorizedEnvironmentReadService {
  _Files(String environmentId)
    : identity = AuthorizedEnvironmentIdentity(
        sessionId: 'session',
        environmentId: environmentId,
      );

  final AuthorizedEnvironmentIdentity identity;
  final directories = <String, List<EnvironmentDirectoryEntry>>{'': []};
  final files = <String, String>{};
  final directoryFailures = <String, Object>{};
  final fileFailures = <String, Object>{};
  final reads = <String>[];

  @override
  Future<AuthorizedEnvironmentIdentity> authority() async => identity;

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    reads.add('directory:$relativePath');
    if (directoryFailures[relativePath] case final failure?) throw failure;
    if (files.containsKey(relativePath)) {
      throw const EnvironmentFailure(
        code: 'not_directory',
        message: 'Not a directory.',
        details: {},
      );
    }
    return EnvironmentDirectoryListing(
      relativePath: relativePath,
      entries: directories[relativePath] ?? [],
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    reads.add('file:$relativePath');
    if (fileFailures[relativePath] case final failure?) throw failure;
    final text = files[relativePath]!;
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: utf8.encode(text).length,
      revision: 'opaque-revision',
    );
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  Map<String, Object?>? response;
  int requestId = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': requestId++,
      'method': method,
      'payload': payload,
    });
    this.response = response;
    if (response['ok'] != true) throw _RemoteFailure(response['error']! as Map);
    return response['payload'];
  }
}

final class _RemoteFailure implements AdeleRemoteFailure {
  const _RemoteFailure(this.error);
  final Map<Object?, Object?> error;

  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code']! as String;
  @override
  String get message => error['message']! as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details']! as Map);
}
