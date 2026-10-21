import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:adele_contract/adele_contract.dart';
import 'package:contract_codegen/contract_codegen.dart';
import 'package:dart_eval/dart_eval.dart';
import 'package:dart_eval/dart_eval_bridge.dart';
import 'package:dart_eval/src/eval/runtime/class.dart' show $InstanceImpl;
import 'package:dart_eval/stdlib/core.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';
import 'package:test/test.dart';

const _selection = <String, Object?>{
  'relativePath': 'dir/two words\t\u03bb.txt',
  'hunkIndex': 2,
  'expectedRevision': 'opaque:review-revision',
};
const _failureCodes = [
  'invalid_selection',
  'stale_selection',
  'unsupported_target',
  'hunk_unavailable',
  'inspection_failed',
  'operation_timeout',
  'mutation_failed',
  'outcome_uncertain',
];

void main() {
  late _Service service;
  late ReviewApprovalHandlerServiceDispatcher dispatcher;
  late _Channel channel;
  late ReviewApprovalHandlerServiceClient client;
  setUp(() {
    service = _Service();
    dispatcher = ReviewApprovalHandlerServiceDispatcher(service);
    channel = _Channel(dispatcher);
    client = ReviewApprovalHandlerServiceClient(channel);
  });
  tearDown(() => dispatcher.close());

  test(
    'review capability and service are separate from read-only snapshots',
    () {
      expect(reviewApprovalCapability.id.value, 'adele.diff.review-approval');
      expect(reviewApprovalCapability.majorVersion, 1);
      expect(reviewApprovalCapability, isNot(changeSetSourceCapability));
      expect(reviewApprovalHandlerServiceId, 'diff.reviewApprovalHandler');
      expect(
        reviewApprovalHandlerServiceApproveHunkId,
        'diff.reviewApprovalHandler.approveHunk',
      );
      expect(
        reviewApprovalHandlerServiceUnapproveHunkId,
        'diff.reviewApprovalHandler.unapproveHunk',
      );
    },
  );

  test(
    'native selection constructors reject invalid values without asserts',
    () {
      for (final wire in _invalidSelections()) {
        expect(
          () => _decodeSelection(wire),
          throwsArgumentError,
          reason: '$wire',
        );
      }
    },
  );

  for (final eval in [false, true]) {
    group(eval ? 'eval transport' : 'native transport', () {
      late ByteData bytecode;
      if (eval) {
        setUpAll(() async {
          final generated = await const ContractGenerator().generateEvalClient(
            File('lib/diff_viewer_contract.dart'),
          );
          final compiler = Compiler()
            ..entrypoints.addAll([
              'package:adele_contract/adele_contract.dart',
              'package:diff_viewer_contract/diff_viewer_contract.dart',
              'package:runner/main.dart',
            ]);
          final program = compiler.compile({
            'adele_contract': {
              'adele_contract.dart': evalContractSupportSource,
            },
            'diff_viewer_contract': {'diff_viewer_contract.dart': generated},
            'runner': {'main.dart': _evalRunner},
          });
          bytecode = program.write().buffer.asByteData();
        });
      }

      Future<Object?> runEval(String entry, List<Object?> arguments) async {
        final runtime = Runtime(bytecode);
        return await runtime.executeLib('package:runner/main.dart', entry, [
          $Closure((_, _, args) {
            final method = args[0]!.$reified as String;
            final payload = jsonDecode(args[1]!.$reified as String);
            return $Future.wrap(
              channel
                  .request(method, Map<String, Object?>.from(payload as Map))
                  .then<$Value>((value) => $String(jsonEncode(value))),
            );
          }),
          for (final argument in arguments)
            argument is String ? $String(argument) : argument,
        ]);
      }

      Future<void> invoke(Map<String, Object?> wire, bool reverse) async {
        if (eval) {
          await runEval('invoke', [jsonEncode(wire), reverse]);
        } else {
          final selection = _decodeSelection(wire);
          if (reverse) {
            await client.unapproveHunk(selection);
          } else {
            await client.approveHunk(selection);
          }
        }
      }

      Future<Object?> raw(String method, Object? payload) => eval
          ? runEval('raw', [method, jsonEncode(payload)])
          : channel.request(method, Map<String, Object?>.from(payload! as Map));

      test(
        'both void methods send only the selected hunk and return null',
        () async {
          for (final reverse in [false, true]) {
            await invoke(_selection, reverse);
            expect(
              channel.method,
              reverse
                  ? reviewApprovalHandlerServiceUnapproveHunkId
                  : reviewApprovalHandlerServiceApproveHunkId,
            );
            expect(channel.payload, {'selection': _selection});
            expect(channel.response, isNull);
            expect(
              service.selections.last.relativePath,
              _selection['relativePath'],
            );
            expect(service.selections.last.hunkIndex, 2);
            expect(
              service.selections.last.expectedRevision,
              'opaque:review-revision',
            );
          }
          expect(service.operations, ['approve', 'unapprove']);
        },
      );

      test(
        'inclusive bounds use UTF-16 paths and printable ASCII revisions',
        () async {
          final longPath = List.filled(2048, '\u{1f600}').join();
          expect(longPath.length, 4096);
          for (final wire in [
            {
              ..._selection,
              'relativePath': 'a',
              'hunkIndex': 0,
              'expectedRevision': ' ',
            },
            {
              ..._selection,
              'relativePath': longPath,
              'hunkIndex': 8191,
              'expectedRevision': List.filled(256, '~').join(),
            },
            {..._selection, 'relativePath': 'dir/line\nbreak.txt'},
            {..._selection, 'relativePath': '.github/.gitignore'},
          ]) {
            for (final reverse in [false, true]) {
              await invoke(wire, reverse);
              expect(
                service.selections.last.relativePath,
                wire['relativePath'],
              );
              expect(service.selections.last.hunkIndex, wire['hunkIndex']);
              expect(
                service.selections.last.expectedRevision,
                wire['expectedRevision'],
              );
            }
          }
        },
      );

      test(
        'declared failures remain failures, never successful void responses',
        () async {
          for (final code in _failureCodes) {
            for (final details in <Map<String, Object?>>[
              const ReviewApprovalFailure(
                code: 'test',
                message: 'test',
              ).details,
              {'freshSnapshotRequired': true, 'attempt': 1},
            ]) {
              service.failure = ReviewApprovalFailure(
                code: code,
                message: 'Review could not complete.',
                details: details,
              );
              for (final reverse in [false, true]) {
                await expectLater(
                  invoke(_selection, reverse),
                  throwsA(
                    eval
                        ? isA<AdeleRemoteFailure>()
                              .having(
                                (error) => error.declaredFailureType,
                                'type',
                                'diff.reviewApprovalFailure',
                              )
                              .having((error) => error.code, 'code', code)
                              .having(
                                (error) => error.message,
                                'message',
                                'Review could not complete.',
                              )
                              .having(
                                (error) => error.details,
                                'details',
                                details,
                              )
                        : isA<ReviewApprovalFailure>()
                              .having((error) => error.code, 'code', code)
                              .having(
                                (error) => error.message,
                                'message',
                                'Review could not complete.',
                              )
                              .having(
                                (error) => error.details,
                                'details',
                                details,
                              ),
                  ),
                );
              }
            }
          }
        },
      );

      test('undeclared provider errors stay opaque', () async {
        service.failure = StateError('private provider diagnostics');
        for (final reverse in [false, true]) {
          await expectLater(
            invoke(_selection, reverse),
            throwsA(
              isA<AdeleRemoteFailure>()
                  .having((error) => error.code, 'code', 'internal_error')
                  .having(
                    (error) => error.message,
                    'message',
                    isNot(contains('private')),
                  ),
            ),
          );
        }
      });

      test('void responses reject non-null data', () async {
        channel.replaceResponse = true;
        for (final response in <Object?>[
          false,
          0,
          '',
          <Object?>[],
          <String, Object?>{},
        ]) {
          channel.replacement = response;
          for (final reverse in [false, true]) {
            if (eval) {
              await expectLater(
                invoke(_selection, reverse),
                throwsA(
                  isA<$InstanceImpl>().having(
                    (error) {
                      final message = error.values.single;
                      return message is $Value ? message.$reified : message;
                    },
                    'protocol message',
                    'Expected null.',
                  ),
                ),
              );
            } else {
              await expectLater(
                invoke(_selection, reverse),
                throwsA(isA<AdeleProtocolException>()),
              );
            }
          }
        }
        expect(service.operations, hasLength(10));
      });

      test(
        'malformed, unknown and authority fields never reach the service',
        () async {
          for (final method in [
            reviewApprovalHandlerServiceApproveHunkId,
            reviewApprovalHandlerServiceUnapproveHunkId,
          ]) {
            for (final payload in _invalidPayloads()) {
              await expectLater(
                raw(method, payload),
                throwsA(
                  isA<AdeleRemoteFailure>().having(
                    (error) => error.code,
                    'code',
                    'invalid_request',
                  ),
                ),
                reason: '$method: $payload',
              );
            }
          }
          expect(service.operations, isEmpty);
        },
      );

      test(
        'snapshot and unknown methods are not approval operations',
        () async {
          for (final method in [
            changeSetSourceServiceSnapshotUnstagedId,
            changeSetSourceServiceSnapshotUncommittedId,
            changeSetSourceServiceSnapshotTaskChangesId,
            'diff.reviewApprovalHandler.applyPatch',
          ]) {
            await expectLater(
              raw(method, {'selection': _selection}),
              throwsA(
                isA<AdeleRemoteFailure>().having(
                  (error) => error.code,
                  'code',
                  'unknown_method',
                ),
              ),
            );
          }
          expect(service.operations, isEmpty);
        },
      );

      if (eval) {
        test(
          'native validation rejects out-of-bounds eval-constructed selections',
          () async {
            for (final wire in _invalidSelections()) {
              for (final reverse in [false, true]) {
                await expectLater(
                  invoke(wire, reverse),
                  throwsA(
                    isA<AdeleRemoteFailure>().having(
                      (error) => error.code,
                      'code',
                      'invalid_request',
                    ),
                  ),
                );
              }
            }
            expect(service.operations, isEmpty);
          },
        );
      }
    });
  }
}

ReviewHunkSelection _decodeSelection(Map<String, Object?> wire) =>
    ReviewHunkSelection(
      relativePath: wire['relativePath']! as String,
      hunkIndex: wire['hunkIndex']! as int,
      expectedRevision: wire['expectedRevision']! as String,
    );

Iterable<Map<String, Object?>> _invalidSelections() sync* {
  for (final path in [
    '',
    '/',
    '/absolute',
    'dir/',
    'dir//file',
    '.',
    '..',
    '.git',
    './file',
    '../file',
    'dir/./file',
    'dir/../file',
    'dir/.git/file',
    'dir/file\u0000name',
    List.filled(4097, 'x').join(),
    '${List.filled(2048, '\u{1f600}').join()}x',
  ]) {
    yield {..._selection, 'relativePath': path};
  }
  for (final index in [-1, 8192]) {
    yield {..._selection, 'hunkIndex': index};
  }
  for (final revision in [
    '',
    '\u0000',
    '\t',
    '\n',
    '\r',
    '\u001f',
    '\u007f',
    '\u0080',
    '\u03bb',
    List.filled(257, 'x').join(),
  ]) {
    yield {..._selection, 'expectedRevision': revision};
  }
}

Iterable<Map<String, Object?>> _invalidPayloads() sync* {
  yield {};
  for (final selection in <Object?>[
    null,
    false,
    'patch',
    <Object?>[],
    <String, Object?>{},
    for (final field in _selection.keys) ...[
      {..._selection}..remove(field),
      {..._selection, field: null},
    ],
    {..._selection, 'relativePath': 1},
    {..._selection, 'hunkIndex': '2'},
    {..._selection, 'hunkIndex': 2.5},
    {..._selection, 'expectedRevision': false},
    ..._invalidSelections(),
  ]) {
    yield {'selection': selection};
  }
  for (final field in [
    'extra',
    'sessionId',
    'environmentId',
    'root',
    'absolutePath',
    'scope',
    'configurationContext',
    'hostInvocationContext',
    'patch',
    'replacementText',
    'providerId',
    'baselineCommit',
    'layer',
  ]) {
    yield {'selection': _selection, field: 'forged'};
    yield {
      'selection': {..._selection, field: 'forged'},
    };
  }
}

class _Service implements ReviewApprovalHandlerService {
  final operations = <String>[];
  final selections = <ReviewHunkSelection>[];
  Object? failure;

  @override
  Future<void> approveHunk(ReviewHunkSelection selection) async {
    operations.add('approve');
    selections.add(selection);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> unapproveHunk(ReviewHunkSelection selection) async {
    operations.add('unapprove');
    selections.add(selection);
    if (failure != null) throw failure!;
  }
}

class _Channel implements AdeleRequestChannel {
  _Channel(this.dispatcher);
  final ReviewApprovalHandlerServiceDispatcher dispatcher;
  String? method;
  Map<String, Object?>? payload;
  Object? response;
  bool replaceResponse = false;
  Object? replacement;

  @override
  Future<Object?> request(String method, Map<String, Object?> payload) async {
    this.method = method;
    this.payload = payload;
    final result = await dispatcher.dispatch({
      'kind': 'request',
      'requestId': 1,
      'method': method,
      'payload': jsonDecode(jsonEncode(payload)),
    });
    if (result['ok'] != true) throw _Failure(result['error']! as Map);
    return response = replaceResponse
        ? replacement
        : jsonDecode(jsonEncode(result['payload']));
  }
}

class _Failure implements AdeleRemoteFailure {
  _Failure(this.error);
  final Map<Object?, Object?> error;
  @override
  String? get declaredFailureType => error['declaredFailureType'] as String?;
  @override
  String get code => error['code'] as String;
  @override
  String get message => error['message'] as String;
  @override
  Map<String, Object?> get details =>
      Map<String, Object?>.from(error['details'] as Map);
}

const _evalRunner = r'''
import 'dart:convert';
import 'package:adele_contract/adele_contract.dart';
import 'package:diff_viewer_contract/diff_viewer_contract.dart';

class Channel implements AdeleRequestChannel {
  Channel(this.send);
  final Function send;
  Future<Object?> request(String method, Map<String, Object?> payload) {
    final callback = send;
    final Future<String> response = callback(method, jsonEncode(payload));
    return response.then((String wire) => jsonDecode(wire));
  }
}

Future<void> invoke(Function send, String wire, bool reverse) async {
  final value = jsonDecode(wire);
  final selection = ReviewHunkSelection(
    relativePath: value['relativePath'],
    hunkIndex: value['hunkIndex'],
    expectedRevision: value['expectedRevision'],
  );
  final ReviewApprovalHandlerServiceClient client = ReviewApprovalHandlerServiceClient(Channel(send));
  if (reverse) {
    await client.unapproveHunk(selection);
  } else {
    await client.approveHunk(selection);
  }
}

Future<Object?> raw(Function send, String method, String wire) {
  return Channel(send).request(method, jsonDecode(wire));
}

''';
