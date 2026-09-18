import 'dart:async';
import 'dart:convert';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_backend_support/adele_plugin_backend_support.dart';
import 'package:adele_product/adele_product.dart';
import 'package:filesystem_tools_backend/filesystem_tools_backend.dart';
import 'package:filesystem_tools_plugin/filesystem_tools_plugin.dart';
import 'package:test/test.dart';

const _routes = <String, String>{
  'read_file': 'dev.adele.plugin.filesystem-tools.read-file',
  'apply_patch': 'dev.adele.plugin.filesystem-tools.apply-patch',
  'create_file': 'dev.adele.plugin.filesystem-tools.create-file',
  'delete_file': 'dev.adele.plugin.filesystem-tools.delete-file',
};

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.close());

  test(
    'descriptors reuse semantic definitions and exact dependencies',
    () async {
      fixture.host.close();
      final local = filesystemToolRegistrations(_NoEffects(), _NoEffects());
      final descriptors = await fixture.client.materialize('session');
      expect(descriptors.map((tool) => tool.modelAlias), _routes.keys);
      for (int index = 0; index < local.length; index++) {
        final descriptor = descriptors[index];
        final registration = local[index];
        expect(descriptor.toolId, _routes[descriptor.modelAlias]);
        expect(descriptor.routeId, descriptor.toolId);
        expect(descriptor.toolDescription, registration.definition.description);
        expect(
          descriptor.modelDescription,
          registration.modelDefinition.description,
        );
        expect(
          descriptor.argumentsSchema,
          registration.modelDefinition.argumentsSchema,
        );
      }
      expect(descriptors.map((tool) => tool.executionHostServices), [
        [authorizedEnvironmentReadServiceId],
        [
          authorizedEnvironmentReadServiceId,
          authorizedEnvironmentMutationServiceId,
        ],
        [authorizedEnvironmentMutationServiceId],
        [
          authorizedEnvironmentReadServiceId,
          authorizedEnvironmentMutationServiceId,
        ],
      ]);
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'validation delegates to each semantic validator without authority',
    () async {
      fixture.host.close();
      for (final registration in filesystemToolRegistrations(
        _NoEffects(),
        _NoEffects(),
      )) {
        final alias = registration.modelDefinition.alias;
        final proposed = _arguments(alias, path: './dir//./source.dart');
        expect(
          (await fixture.client.validateAndNormalize(
            _routes[alias]!,
            proposed,
          )).snapshot,
          (await registration.executable.validateAndNormalize(
            proposed,
          )).snapshot,
        );
        final invalid = <String, Object?>{
          ...proposed,
          'environmentId': 'forbidden',
        };
        late String message;
        try {
          await registration.executable.validateAndNormalize(invalid);
          fail('Semantic validation unexpectedly succeeded.');
        } on ToolArgumentValidationException catch (error) {
          message = error.message;
        }
        await expectLater(
          fixture.client.validateAndNormalize(_routes[alias]!, invalid),
          throwsA(
            isA<RemoteToolArgumentValidationFailure>()
                .having((error) => error.code, 'code', 'invalid_arguments')
                .having((error) => error.message, 'message', message)
                .having((error) => error.details, 'details', isEmpty),
          ),
        );
      }
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'description uses identity only and preserves every semantic effect',
    () async {
      fixture.host.close();
      for (final environment in ['environment-one', 'environment-two']) {
        final facets = _NoEffects(environmentId: environment);
        for (final registration in filesystemToolRegistrations(
          facets,
          facets,
        )) {
          final arguments = await registration.executable.validateAndNormalize(
            _arguments(
              registration.modelDefinition.alias,
              path: './dir//source.dart',
            ),
          );
          final local = await registration.executable.describe(
            arguments,
            ToolExecutionContext(
              sessionId: facets.sessionId,
              runId: RunId('run'),
            ),
          );
          final remote = await fixture.client.describe(
            registration.definition.id.value,
            RemoteCanonicalToolArguments.fromLocal(arguments),
            'session',
            'run',
            environment,
          );
          expect(
            remote.effects.map((effect) => effect.name),
            local.effects.map((effect) => effect.name),
          );
          expect(remote.targetUris, [
            Uri.parse('adele-environment:/$environment/dir/source.dart'),
          ]);
          expect(remote.summary, local.summary);
          expect(remote.uncertainty, RemoteEffectUncertainty.none);
        }
      }
      expect(fixture.requests, isEmpty);
    },
  );

  test('each route maps exact generated calls and terminal evidence', () async {
    for (final alias in _routes.keys) {
      final token = 'invocation-$alias';
      fixture.bind(
        token,
        read: alias != 'create_file',
        mutation: alias != 'read_file',
      );
      fixture.requests.clear();
      final outcome = await fixture.execute(alias, token: token);
      expect(outcome.disposition, RemoteToolOutcomeDisposition.success);
      expect(outcome.effectCertainty, RemoteEffectCertainty.knownOccurred);
      expect(outcome.toLocal().cause, isNull);
      expect(outcome.hostData['environmentId'], 'environment-data');
      expect(outcome.hostData['relativePath'], 'dir/source.dart');
      final calls = [
        for (final request in fixture.requests)
          [request['serviceId'], request['method'], request['payload']],
      ];
      final read = [
        authorizedEnvironmentReadServiceId,
        authorizedEnvironmentReadServiceReadFileId,
        {'relativePath': 'dir/source.dart'},
      ];
      switch (alias) {
        case 'read_file':
          expect(calls, [read]);
          expect(outcome.hostData['text'], 'old\n');
          expect(outcome.hostData['revision'], 'R1');
          expect(outcome.hostData['sizeBytes'], 9);
          expect(outcome.hostData['nextStartLine'], 2);
        case 'apply_patch':
          expect(calls, [
            read,
            [
              authorizedEnvironmentMutationServiceId,
              authorizedEnvironmentMutationServiceReplaceExistingTextFileId,
              {
                'relativePath': 'dir/source.dart',
                'replacementText': 'new\nkeep\n',
                'expectedRevision': 'R1',
              },
            ],
          ]);
          expect(outcome.hostData['newRevision'], 'R2');
          expect(outcome.hostData['editCount'], 1);
        case 'create_file':
          expect(calls, [
            [
              authorizedEnvironmentMutationServiceId,
              authorizedEnvironmentMutationServiceCreateTextFileId,
              {'relativePath': 'dir/source.dart', 'text': 'new\n'},
            ],
          ]);
          expect(outcome.hostData['revision'], 'C1');
        case 'delete_file':
          expect(calls, [
            read,
            [
              authorizedEnvironmentMutationServiceId,
              authorizedEnvironmentMutationServiceDeleteExistingTextFileId,
              {'relativePath': 'dir/source.dart', 'expectedRevision': 'R1'},
            ],
          ]);
          expect(outcome.modelContent, 'Deleted: "dir/source.dart"');
      }
      for (final request in fixture.requests) {
        expect(request['kind'], 'hostRequest');
        expect(request['hostInvocationContext'], token);
        expect(request.keys.toSet(), {
          'kind',
          'requestId',
          'hostInvocationContext',
          'serviceId',
          'method',
          'payload',
        });
      }
    }
  });

  test(
    'declared mutation failures retain domain classification and certainty',
    () async {
      for (final alias in ['apply_patch', 'create_file', 'delete_file']) {
        final method = _mutationMethod(alias);
        final expectedCode = alias == 'create_file'
            ? environmentFileAlreadyExistsCode
            : environmentRevisionConflictCode;
        for (final code in [expectedCode, 'unwritable']) {
          final files = fixture.bind('$alias-$code');
          files.failures[method] = EnvironmentFailure(
            code: code,
            message: 'Exact provider failure.',
            details: const {'evidence': 'retained'},
          );
          final outcome = await fixture.execute(alias, token: '$alias-$code');
          expect(outcome.failureKind, RemoteToolFailureKind.domain);
          expect(outcome.hostData['code'], code);
          expect(
            outcome.effectCertainty,
            code == expectedCode
                ? RemoteEffectCertainty.knownNotOccurred
                : RemoteEffectCertainty.uncertain,
          );
          if (code == 'unwritable') {
            expect(outcome.hostData['details'], {'evidence': 'retained'});
            expect(outcome.hostDiagnostic, 'Exact provider failure.');
          }
          expect(outcome.toLocal().cause, isNull);
        }
      }
    },
  );

  test(
    'remote preflight rejects revisions and incomplete edits without mutation',
    () async {
      fixture.bind('preflight');
      for (final alias in ['apply_patch', 'delete_file']) {
        fixture.requests.clear();
        final outcome = await fixture.execute(
          alias,
          token: 'preflight',
          proposed: {..._arguments(alias), 'expectedRevision': 'stale'},
        );
        expect(outcome.hostData['code'], environmentRevisionConflictCode);
        expect(outcome.failureKind, RemoteToolFailureKind.domain);
        expect(outcome.effectCertainty, RemoteEffectCertainty.knownNotOccurred);
        expect(
          fixture.requests.single['serviceId'],
          authorizedEnvironmentReadServiceId,
        );
      }
      for (final replacement in ['missing', 'old']) {
        fixture.requests.clear();
        final outcome = await fixture.execute(
          'apply_patch',
          token: 'preflight',
          proposed: {
            ..._arguments('apply_patch'),
            'edits': [
              {'search': 'old', 'replace': 'intermediate'},
              {
                'search': replacement == 'missing' ? 'missing' : 'intermediate',
                'replace': replacement,
              },
            ],
          },
        );
        expect(outcome.effectCertainty, RemoteEffectCertainty.knownNotOccurred);
        if (replacement == 'missing') {
          expect(outcome.hostData['failedEditIndex'], 1);
        } else {
          expect(outcome.hostData['code'], 'no_change');
        }
        expect(
          fixture.requests.single['serviceId'],
          authorizedEnvironmentReadServiceId,
        );
      }
      fixture.requests.clear();
      final completed = await fixture.execute(
        'apply_patch',
        token: 'preflight',
        proposed: {
          ..._arguments('apply_patch'),
          'edits': [
            {'search': 'old', 'replace': 'intermediate'},
            {'search': 'intermediate', 'replace': 'final'},
          ],
        },
      );
      expect(completed.disposition, RemoteToolOutcomeDisposition.success);
      expect(fixture.requests, hasLength(2));
      expect(fixture.requests.last['payload'], {
        'relativePath': 'dir/source.dart',
        'replacementText': 'final\nkeep\n',
        'expectedRevision': 'R1',
      });
    },
  );

  test(
    'read failures stay before mutation and undeclared errors stay infrastructure',
    () async {
      for (final alias in ['read_file', 'apply_patch', 'delete_file']) {
        for (final declared in [true, false]) {
          final files = fixture.bind('$alias-$declared');
          files.failures[authorizedEnvironmentReadServiceReadFileId] = declared
              ? const EnvironmentFailure(
                  code: 'not_found',
                  message: 'Missing.',
                  details: {'path': 'source.dart'},
                )
              : StateError('private provider detail');
          fixture.requests.clear();
          final outcome = await fixture.execute(
            alias,
            token: '$alias-$declared',
          );
          expect(
            outcome.failureKind,
            declared
                ? RemoteToolFailureKind.domain
                : RemoteToolFailureKind.infrastructure,
          );
          expect(
            outcome.effectCertainty,
            alias == 'read_file'
                ? RemoteEffectCertainty.uncertain
                : RemoteEffectCertainty.knownNotOccurred,
          );
          expect(
            fixture.requests.single['serviceId'],
            authorizedEnvironmentReadServiceId,
          );
          if (declared) {
            expect(outcome.hostData['code'], 'not_found');
            expect(outcome.hostData['details'], {'path': 'source.dart'});
          } else {
            expect(outcome.hostData.containsKey('code'), isFalse);
            expect(
              outcome.hostDiagnostic,
              isNot(contains('private provider detail')),
            );
          }
        }
      }
      for (final alias in ['apply_patch', 'create_file', 'delete_file']) {
        fixture.bind(alias).failures[_mutationMethod(alias)] = StateError(
          'private provider detail',
        );
        final outcome = await fixture.execute(alias, token: alias);
        expect(outcome.failureKind, RemoteToolFailureKind.infrastructure);
        expect(outcome.effectCertainty, RemoteEffectCertainty.uncertain);
        expect(outcome.hostData.containsKey('code'), isFalse);
        expect(
          outcome.hostDiagnostic,
          isNot(contains('private provider detail')),
        );
      }
    },
  );

  test(
    'execution never reuses an earlier invocation or selects authority by IDs',
    () async {
      fixture.bind('first');
      fixture.bind('second').text = 'second\n';
      final first = await fixture.execute('read_file', token: 'first');
      final second = await fixture.execute('read_file', token: 'second');
      expect(first.hostData['text'], 'old\n');
      expect(second.hostData['text'], 'second\n');
      fixture.services.remove('first');
      final expired = await fixture.execute('apply_patch', token: 'first');
      expect(expired.failureKind, RemoteToolFailureKind.infrastructure);
      expect(expired.effectCertainty, RemoteEffectCertainty.knownNotOccurred);
      expect(
        fixture.requests.map((request) => request['hostInvocationContext']),
        ['first', 'second', 'first'],
      );
      expect(
        fixture.requests.every(
          (request) =>
              request['method'] == authorizedEnvironmentReadServiceReadFileId,
        ),
        isTrue,
      );
    },
  );

  test(
    'unknown routes and malformed wrappers are not argument rejection',
    () async {
      for (final route in ['read_file', '', 'unknown']) {
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
            RemoteCanonicalToolArguments(snapshot: {}),
            'session',
            'run',
            'environment',
          ),
          throwsA(isA<AdeleRemoteFailure>()),
        );
        await expectLater(
          fixture.backend.execute(
            route,
            RemoteCanonicalToolArguments(snapshot: {}),
            'session',
            'run',
            'environment',
            'token',
          ),
          emitsError(isArgumentError),
        );
      }
      for (final payload in <Map<String, Object?>>[
        {'routeId': _routes['read_file'], 'proposedArguments': 'bad'},
        {
          'routeId': _routes['read_file'],
          'proposedArguments': {},
          'hostInvocationContext': 'forbidden',
        },
      ]) {
        final response = await fixture.forward.dispatch({
          'kind': 'request',
          'requestId': 99,
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
    'missing identity or invocation fails before any generated effect',
    () async {
      final arguments = RemoteCanonicalToolArguments(
        snapshot: _arguments('create_file'),
      );
      await expectLater(
        fixture.client.describe(
          _routes['create_file']!,
          arguments,
          'session',
          'run',
          null,
        ),
        throwsA(isA<AdeleRemoteFailure>()),
      );
      for (final token in <String?>[null, '']) {
        await expectLater(
          fixture.backend.execute(
            _routes['create_file']!,
            arguments,
            'session',
            'run',
            'environment',
            token,
          ),
          emitsError(isNot(isA<RemoteToolArgumentValidationFailure>())),
        );
      }
      await expectLater(
        fixture.backend.execute(
          _routes['create_file']!,
          arguments,
          'session',
          'run',
          null,
          'token',
        ),
        emitsError(isStateError),
      );
      expect(fixture.requests, isEmpty);
    },
  );
}

Map<String, Object?> _arguments(
  String alias, {
  String path = 'dir/source.dart',
}) => {
  'relativePath': path,
  if (alias == 'read_file') 'lineCount': 1,
  if (alias == 'apply_patch' || alias == 'delete_file')
    'expectedRevision': 'R1',
  if (alias == 'apply_patch')
    'edits': [
      {'search': 'old', 'replace': 'new'},
    ],
  if (alias == 'create_file') 'content': 'new\n',
};

String _mutationMethod(String alias) => switch (alias) {
  'apply_patch' =>
    authorizedEnvironmentMutationServiceReplaceExistingTextFileId,
  'create_file' => authorizedEnvironmentMutationServiceCreateTextFileId,
  'delete_file' => authorizedEnvironmentMutationServiceDeleteExistingTextFileId,
  _ => throw StateError('Not a mutation tool.'),
};

final class _NoEffects
    implements
        AuthorizedEnvironmentFileReadFacet,
        AuthorizedEnvironmentFileMutationFacet {
  _NoEffects({String environmentId = 'environment'})
    : environmentId = EnvironmentId(environmentId);

  @override
  final SessionId sessionId = SessionId('session');
  @override
  final EnvironmentId environmentId;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No effects allowed.');
}

final class _Fixture {
  final requests = <Map<String, Object?>>[];
  final services = <String, Map<String, AdeleBackendDispatcher>>{};
  final dispatchers = <AdeleBackendDispatcher>[];
  late final host = AdeleHostRequestMultiplexer(
    send: (request) {
      requests.add(request);
      unawaited(_respond(request));
    },
  );
  late final backend = FilesystemToolsBackend(host);
  late final forward = RemoteModelToolServiceDispatcher(backend);
  late final client = RemoteModelToolServiceClient(_Channel(forward));

  _Files bind(String token, {bool read = true, bool mutation = true}) {
    final files = _Files();
    final bound = <String, AdeleBackendDispatcher>{
      if (read)
        authorizedEnvironmentReadServiceId:
            AuthorizedEnvironmentReadServiceDispatcher(files),
      if (mutation)
        authorizedEnvironmentMutationServiceId:
            AuthorizedEnvironmentMutationServiceDispatcher(files),
    };
    services[token] = bound;
    dispatchers.addAll(bound.values);
    return files;
  }

  Future<RemoteToolOutcome> execute(
    String alias, {
    required String token,
    Map<String, Object?>? proposed,
  }) async {
    final arguments = await client.validateAndNormalize(
      _routes[alias]!,
      proposed ?? _arguments(alias, path: './dir//source.dart'),
    );
    final event = await backend
        .execute(
          _routes[alias]!,
          arguments,
          'session-data',
          'run-data',
          'environment-data',
          token,
        )
        .single;
    expect(event.kind, RemoteToolExecutionEventKind.terminal);
    expect(event.progress, isNull);
    return event.outcome!;
  }

  Future<void> _respond(Map<String, Object?> request) async {
    final dispatcher =
        services[request['hostInvocationContext']]?[request['serviceId']];
    final response = dispatcher == null
        ? <String, Object?>{
            'ok': false,
            'error': {
              'code': 'host_invocation_unavailable',
              'message': 'Operation or service unavailable.',
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

final class _Files
    implements
        AuthorizedEnvironmentReadService,
        AuthorizedEnvironmentMutationService {
  String text = 'old\nkeep\n';
  final failures = <String, Object>{};

  void _fail(String method) {
    if (failures[method] case final error?) throw error;
  }

  @override
  Future<AuthorizedEnvironmentIdentity> authority() =>
      throw StateError('Identity must not be queried.');

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      throw StateError('Filesystem tools do not traverse.');

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    _fail(authorizedEnvironmentReadServiceReadFileId);
    return EnvironmentTextFile(
      relativePath: relativePath,
      text: text,
      sizeBytes: utf8.encode(text).length,
      revision: 'R1',
    );
  }

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) async {
    _fail(authorizedEnvironmentMutationServiceCreateTextFileId);
    return EnvironmentTextFileCreation(revision: 'C1');
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    _fail(authorizedEnvironmentMutationServiceReplaceExistingTextFileId);
    return const EnvironmentTextFileReplacement(revision: 'R2');
  }

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    _fail(authorizedEnvironmentMutationServiceDeleteExistingTextFileId);
  }
}

final class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final AdeleBackendDispatcher dispatcher;
  int requestId = 0;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    final response = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': requestId++,
      'method': method,
      'payload': payload,
    });
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
