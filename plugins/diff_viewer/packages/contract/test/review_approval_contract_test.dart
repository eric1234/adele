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
      expect(
        reviewApprovalHandlerServiceApproveFileId,
        'diff.reviewApprovalHandler.approveFile',
      );
      expect(
        reviewApprovalHandlerServiceUnapproveFileId,
        'diff.reviewApprovalHandler.unapproveFile',
      );
      expect(
        reviewApprovalHandlerServiceApproveAllUnstagedId,
        'diff.reviewApprovalHandler.approveAllUnstaged',
      );
      expect(
        reviewApprovalHandlerServiceUnapproveAllStagedId,
        'diff.reviewApprovalHandler.unapproveAllStaged',
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
      for (final wire in _invalidSelections(wholeFile: true)) {
        expect(() => _decodeFileSelection(wire), throwsArgumentError);
      }
      for (final wire in _invalidSelections(wholeLayer: true)) {
        expect(() => _decodeLayerSelection(wire), throwsArgumentError);
      }
    },
  );

  for (final (kind, eval) in [
    for (final kind in ['hunk', 'file', 'layer'])
      for (final eval in [false, true]) (kind, eval),
  ]) {
    final wholeFile = kind == 'file';
    final wholeLayer = kind == 'layer';
    final selectionWire = {..._selection};
    if (wholeFile || wholeLayer) selectionWire.remove('hunkIndex');
    if (wholeLayer) selectionWire.remove('relativePath');
    final approveId = wholeLayer
        ? reviewApprovalHandlerServiceApproveAllUnstagedId
        : wholeFile
        ? reviewApprovalHandlerServiceApproveFileId
        : reviewApprovalHandlerServiceApproveHunkId;
    final unapproveId = wholeLayer
        ? reviewApprovalHandlerServiceUnapproveAllStagedId
        : wholeFile
        ? reviewApprovalHandlerServiceUnapproveFileId
        : reviewApprovalHandlerServiceUnapproveHunkId;
    final transport = eval ? 'eval' : 'native';
    group('$kind $transport transport', () {
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
          await runEval(
            wholeLayer
                ? 'invokeLayer'
                : wholeFile
                ? 'invokeFile'
                : 'invoke',
            [jsonEncode(wire), reverse],
          );
        } else if (wholeLayer) {
          final selection = _decodeLayerSelection(wire);
          if (reverse) {
            await client.unapproveAllStaged(selection);
          } else {
            await client.approveAllUnstaged(selection);
          }
        } else if (wholeFile) {
          final selection = _decodeFileSelection(wire);
          if (reverse) {
            await client.unapproveFile(selection);
          } else {
            await client.approveFile(selection);
          }
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
        'both void methods send only the typed selection and return null',
        () async {
          for (final reverse in [false, true]) {
            await invoke(selectionWire, reverse);
            expect(channel.method, reverse ? unapproveId : approveId);
            expect(channel.payload, {'selection': selectionWire});
            expect(channel.response, isNull);
            if (!wholeLayer) {
              expect(
                wholeFile
                    ? service.fileSelections.last.relativePath
                    : service.selections.last.relativePath,
                _selection['relativePath'],
              );
              if (!wholeFile) expect(service.selections.last.hunkIndex, 2);
            }
            expect(
              wholeLayer
                  ? service.layerSelections.last.expectedRevision
                  : wholeFile
                  ? service.fileSelections.last.expectedRevision
                  : service.selections.last.expectedRevision,
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
              ...selectionWire,
              if (!wholeLayer) 'relativePath': 'a',
              if (kind == 'hunk') 'hunkIndex': 0,
              'expectedRevision': ' ',
            },
            {
              ...selectionWire,
              if (!wholeLayer) 'relativePath': longPath,
              if (kind == 'hunk') 'hunkIndex': 8191,
              'expectedRevision': List.filled(256, '~').join(),
            },
            if (!wholeLayer)
              {...selectionWire, 'relativePath': 'dir/line\nbreak.txt'},
            if (!wholeLayer)
              {...selectionWire, 'relativePath': '.github/.gitignore'},
          ]) {
            for (final reverse in [false, true]) {
              await invoke(wire, reverse);
              if (!wholeLayer) {
                expect(
                  wholeFile
                      ? service.fileSelections.last.relativePath
                      : service.selections.last.relativePath,
                  wire['relativePath'],
                );
              }
              if (kind == 'hunk') {
                expect(service.selections.last.hunkIndex, wire['hunkIndex']);
              }
              expect(
                wholeLayer
                    ? service.layerSelections.last.expectedRevision
                    : wholeFile
                    ? service.fileSelections.last.expectedRevision
                    : service.selections.last.expectedRevision,
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
                  invoke(selectionWire, reverse),
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
            invoke(selectionWire, reverse),
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
                invoke(selectionWire, reverse),
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
                invoke(selectionWire, reverse),
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
          for (final method in [approveId, unapproveId]) {
            for (final payload in _invalidPayloads(
              wholeFile: wholeFile,
              wholeLayer: wholeLayer,
            )) {
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
              raw(method, {'selection': selectionWire}),
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
            for (final wire in _invalidSelections(
              wholeFile: wholeFile,
              wholeLayer: wholeLayer,
            )) {
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

ReviewFileSelection _decodeFileSelection(Map<String, Object?> wire) =>
    ReviewFileSelection(
      relativePath: wire['relativePath']! as String,
      expectedRevision: wire['expectedRevision']! as String,
    );

ReviewLayerSelection _decodeLayerSelection(Map<String, Object?> wire) =>
    ReviewLayerSelection(expectedRevision: wire['expectedRevision']! as String);

ReviewHunkSelection _decodeSelection(Map<String, Object?> wire) =>
    ReviewHunkSelection(
      relativePath: wire['relativePath']! as String,
      hunkIndex: wire['hunkIndex']! as int,
      expectedRevision: wire['expectedRevision']! as String,
    );

Iterable<Map<String, Object?>> _invalidSelections({
  bool wholeFile = false,
  bool wholeLayer = false,
}) sync* {
  final selection = {..._selection};
  if (wholeFile || wholeLayer) selection.remove('hunkIndex');
  if (wholeLayer) selection.remove('relativePath');
  for (final path
      in wholeLayer
          ? <String>[]
          : [
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
    yield {...selection, 'relativePath': path};
  }
  for (final index in wholeFile || wholeLayer ? <int>[] : [-1, 8192]) {
    yield {...selection, 'hunkIndex': index};
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
    yield {...selection, 'expectedRevision': revision};
  }
}

Iterable<Map<String, Object?>> _invalidPayloads({
  bool wholeFile = false,
  bool wholeLayer = false,
}) sync* {
  final valid = {..._selection};
  if (wholeFile || wholeLayer) valid.remove('hunkIndex');
  if (wholeLayer) valid.remove('relativePath');
  yield {};
  for (final selection in <Object?>[
    null,
    false,
    'patch',
    <Object?>[],
    <String, Object?>{},
    for (final field in valid.keys) ...[
      {...valid}..remove(field),
      {...valid, field: null},
    ],
    {...valid, 'relativePath': 1},
    {...valid, 'hunkIndex': '2'},
    {...valid, 'hunkIndex': 2.5},
    if (wholeFile) {...valid, 'hunkIndex': -1},
    if (wholeFile) {...valid, 'hunkIndex': 0},
    {...valid, 'expectedRevision': false},
    ..._invalidSelections(wholeFile: wholeFile, wholeLayer: wholeLayer),
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
    'gitDirectory',
    'branch',
    'executable',
    'argv',
    'fileContents',
    'paths',
    'actions',
    'selections',
    if (wholeLayer) 'relativePath',
    if (wholeLayer) 'hunkIndex',
  ]) {
    yield {'selection': valid, field: 'forged'};
    yield {
      'selection': {...valid, field: 'forged'},
    };
  }
  if (wholeLayer) {
    for (final field in ['paths', 'actions', 'selections']) {
      yield {'selection': valid, field: <Object?>[]};
      yield {
        'selection': {...valid, field: <Object?>[]},
      };
    }
  }
}

class _Service implements ReviewApprovalHandlerService {
  final operations = <String>[];
  final selections = <ReviewHunkSelection>[];
  final fileSelections = <ReviewFileSelection>[];
  final layerSelections = <ReviewLayerSelection>[];
  Object? failure;

  @override
  Future<void> approveAllUnstaged(ReviewLayerSelection selection) async {
    operations.add('approve');
    layerSelections.add(selection);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> unapproveAllStaged(ReviewLayerSelection selection) async {
    operations.add('unapprove');
    layerSelections.add(selection);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> approveFile(ReviewFileSelection selection) async {
    operations.add('approve');
    fileSelections.add(selection);
    if (failure != null) throw failure!;
  }

  @override
  Future<void> unapproveFile(ReviewFileSelection selection) async {
    operations.add('unapprove');
    fileSelections.add(selection);
    if (failure != null) throw failure!;
  }

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

Future<void> invokeFile(Function send, String wire, bool reverse) async {
  final value = jsonDecode(wire);
  final selection = ReviewFileSelection(
    relativePath: value['relativePath'],
    expectedRevision: value['expectedRevision'],
  );
  final ReviewApprovalHandlerServiceClient client = ReviewApprovalHandlerServiceClient(Channel(send));
  if (reverse) {
    await client.unapproveFile(selection);
  } else {
    await client.approveFile(selection);
  }
}

Future<void> invokeLayer(Function send, String wire, bool reverse) async {
  final value = jsonDecode(wire);
  final selection = ReviewLayerSelection(expectedRevision: value['expectedRevision']);
  final ReviewApprovalHandlerServiceClient client = ReviewApprovalHandlerServiceClient(Channel(send));
  if (reverse) {
    await client.unapproveAllStaged(selection);
  } else {
    await client.approveAllUnstaged(selection);
  }
}

''';
