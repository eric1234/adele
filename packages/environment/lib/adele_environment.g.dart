// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'adele_environment.dart';

const String authorizedEnvironmentMutationServiceId =
    'authorizedEnvironmentMutation';
const String authorizedEnvironmentMutationServiceCreateTextFileId =
    'authorizedEnvironmentMutation.createTextFile';
const String authorizedEnvironmentMutationServiceDeleteExistingTextFileId =
    'authorizedEnvironmentMutation.deleteExistingTextFile';
const String authorizedEnvironmentMutationServiceReplaceExistingTextFileId =
    'authorizedEnvironmentMutation.replaceExistingTextFile';

final class AuthorizedEnvironmentMutationServiceClient
    implements AuthorizedEnvironmentMutationService {
  const AuthorizedEnvironmentMutationServiceClient(
    AdeleRequestChannel _adeleChannel,
  ) : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) async {
    try {
      return _decodeEnvironmentTextFileCreation(
        await this._adeleChannel.request(
          authorizedEnvironmentMutationServiceCreateTextFileId,
          <String, Object?>{'relativePath': relativePath, 'text': text},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError0) {
      switch (_adeleError0.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError0.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError0.code,
              message: _adeleError0.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    try {
      final _adeleResponse12 = await this._adeleChannel.request(
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId,
        <String, Object?>{
          'relativePath': relativePath,
          'expectedRevision': expectedRevision,
        },
      );
      _contractVoid(_adeleResponse12, 'deleteExistingTextFile');
      return;
    } on AdeleRemoteFailure catch (_adeleError7) {
      switch (_adeleError7.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError7.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError7.code,
              message: _adeleError7.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    try {
      return _decodeEnvironmentTextFileReplacement(
        await this._adeleChannel.request(
          authorizedEnvironmentMutationServiceReplaceExistingTextFileId,
          <String, Object?>{
            'relativePath': relativePath,
            'replacementText': replacementText,
            'expectedRevision': expectedRevision,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError13) {
      switch (_adeleError13.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError13.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError13.code,
              message: _adeleError13.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class AuthorizedEnvironmentMutationServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class AuthorizedEnvironmentMutationServiceDispatcher
    implements AuthorizedEnvironmentMutationServiceRequestDispatcher {
  AuthorizedEnvironmentMutationServiceDispatcher(this._adeleService);
  final AuthorizedEnvironmentMutationService _adeleService;
  Future<void> _adeleOrdinaryTail = Future<void>.value();
  final Set<Future<void>> _adeleOperations = <Future<void>>{};
  Future<void>? _adeleCloseFuture;
  bool _adeleClosed = false;
  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0) {
    if (_adeleClosed)
      return Future<Map<String, Object?>>.error(
        StateError('The dispatcher is closed.'),
      );
    return _adeleScheduleOrdinary<Map<String, Object?>>(
      () => _adeleDispatchCore(_adeleRequest0),
    );
  }

  Future<Map<String, Object?>> _adeleDispatchCore(
    Map<Object?, Object?> _adeleRequest0,
  ) async {
    final _adeleRequestId1 = _adeleRequest0['requestId'];
    late final String _adeleMethod2;
    try {
      _adeleMethod2 = _decodeContractEnvelope(_adeleRequest0, 'request');
    } on AdeleProtocolException catch (_adeleError3) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError3.message,
        const {},
      );
    }
    if (!const {
      authorizedEnvironmentMutationServiceCreateTextFileId,
      authorizedEnvironmentMutationServiceDeleteExistingTextFileId,
      authorizedEnvironmentMutationServiceReplaceExistingTextFileId,
    }.contains(_adeleMethod2))
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    late final Map<Object?, Object?> _adelePayload4;
    try {
      _adelePayload4 = _contractMap(
        _adeleRequest0['payload'],
        'request payload',
      );
    } on AdeleProtocolException catch (_adeleError5) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError5.message,
        const {},
      );
    }
    late final Object? _adeleArguments6;
    try {
      _adeleArguments6 = switch (_adeleMethod2) {
        authorizedEnvironmentMutationServiceCreateTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
            'text',
          }, 'createTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(_adelePayload4['text'], 'text'),
          ];
        })(),
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
            'expectedRevision',
          }, 'deleteExistingTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(
              _adelePayload4['expectedRevision'],
              'expectedRevision',
            ),
          ];
        })(),
        authorizedEnvironmentMutationServiceReplaceExistingTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
            'replacementText',
            'expectedRevision',
          }, 'replaceExistingTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(
              _adelePayload4['replacementText'],
              'replacementText',
            ),
            _contractString(
              _adelePayload4['expectedRevision'],
              'expectedRevision',
            ),
          ];
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on AdeleProtocolException catch (_adeleError7) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError7.message,
        const {},
      );
    }
    late final Object? _adeleResult8;
    try {
      _adeleResult8 = await switch (_adeleMethod2) {
        authorizedEnvironmentMutationServiceCreateTextFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.createTextFile(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
          );
        })(),
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId =>
          (() async {
            final _adeleValues0 = _adeleArguments6 as List<Object?>;
            await this._adeleService.deleteExistingTextFile(
              _adeleValues0[0] as String,
              _adeleValues0[1] as String,
            );
            return null;
          })(),
        authorizedEnvironmentMutationServiceReplaceExistingTextFileId =>
          (() async {
            final _adeleValues0 = _adeleArguments6 as List<Object?>;
            return await this._adeleService.replaceExistingTextFile(
              _adeleValues0[0] as String,
              _adeleValues0[1] as String,
              _adeleValues0[2] as String,
            );
          })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on EnvironmentFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          environmentFailureTypeId,
          _adeleError9.code,
          _adeleError9.message,
          _contractJsonMap(_adeleError9.details, 'failure details'),
        );
      } on Object {
        return _contractFailure(
          _adeleRequestId1,
          null,
          'backend_contract_violation',
          'The backend violated its generated contract.',
          const {},
        );
      }
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on Object catch (_adeleError10) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'internal_error',
        'The backend request failed unexpectedly.',
        const {},
      );
    }
    try {
      final _adeleEncoded11 = switch (_adeleMethod2) {
        authorizedEnvironmentMutationServiceCreateTextFileId =>
          _encodeEnvironmentTextFileCreation(
            (_adeleResult8 as EnvironmentTextFileCreation),
          ),
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId => null,
        authorizedEnvironmentMutationServiceReplaceExistingTextFileId =>
          _encodeEnvironmentTextFileReplacement(
            (_adeleResult8 as EnvironmentTextFileReplacement),
          ),
        _ => throw const _ContractUnknownMethod(),
      };
      return {
        'kind': 'response',
        'requestId': _adeleRequestId1,
        'ok': true,
        'payload': _adeleEncoded11,
      };
    } on Object {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'backend_contract_violation',
        'The backend violated its generated contract.',
        const {},
      );
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> _adeleCommand0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) {
    if (_adeleClosed) return Future<void>.value();
    return _adeleScheduleOrdinary<void>(
      () async => _adeleSend1(await _adeleDispatchCore(_adeleCommand0)),
    );
  }

  Future<T> _adeleScheduleOrdinary<T>(Future<T> Function() _adeleBody0) {
    final Future<T> _adeleResult1 = _adeleOrdinaryTail.then(
      (_) => _adeleBody0(),
    );
    late final Future<void> _adeleSettlement2;
    _adeleSettlement2 = _adeleResult1
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() => _adeleOperations.remove(_adeleSettlement2));
    _adeleOrdinaryTail = _adeleSettlement2;
    _adeleOperations.add(_adeleSettlement2);
    return _adeleResult1;
  }

  @override
  Future<void> close() => _adeleCloseFuture ??= _adeleClose();
  Future<void> _adeleClose() async {
    _adeleClosed = true;
    await Future.wait<void>(_adeleOperations.toList(growable: false));
  }
}

const String authorizedEnvironmentProcessServiceId =
    'authorizedEnvironmentProcess';
const String authorizedEnvironmentProcessServiceRunForegroundProcessId =
    'authorizedEnvironmentProcess.runForegroundProcess';

final class AuthorizedEnvironmentProcessServiceClient
    implements AuthorizedEnvironmentProcessService {
  const AuthorizedEnvironmentProcessServiceClient(
    AdeleRequestChannel _adeleChannel,
  ) : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) => AdeleLazyStream<EnvironmentProcessEvent>((
    _adeleOnData0,
    _adeleOnError1,
    _adeleOnDone2,
    _adeleCancelOnError3,
  ) {
    final _adeleStreamChannel4 = this._adeleChannel;
    if (_adeleStreamChannel4 is! AdeleStreamChannel)
      throw StateError('This generated method requires an AdeleStreamChannel.');
    final _adeleRaw43 = _adeleStreamChannel4.stream(
      authorizedEnvironmentProcessServiceRunForegroundProcessId,
      <String, Object?>{
        'request': _encodeEnvironmentForegroundProcessRequest(request),
      },
    );
    return adeleDecodedStream<EnvironmentProcessEvent>(
      _adeleRaw43,
      (Object? _adeleItem5) => _decodeEnvironmentProcessEvent(_adeleItem5),
      (Object _adeleError42) {
        if (_adeleError42 is AdeleRemoteFailure) {
          switch (_adeleError42.declaredFailureType) {
            case environmentFailureTypeId:
              final _adeleDetails8 = _contractJsonMap(
                _adeleError42.details,
                'failure details',
              );
              throw _contractConstruct(
                'EnvironmentFailure',
                () => EnvironmentFailure(
                  code: _adeleError42.code,
                  message: _adeleError42.message,
                  details: _adeleDetails8,
                ),
              );
            default:
              break;
          }
        }
        return _adeleError42;
      },
    ).listen(
      _adeleOnData0,
      onError: _adeleOnError1,
      onDone: _adeleOnDone2,
      cancelOnError: _adeleCancelOnError3,
    );
  });
}

abstract interface class AuthorizedEnvironmentProcessServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class AuthorizedEnvironmentProcessServiceDispatcher
    implements AuthorizedEnvironmentProcessServiceRequestDispatcher {
  AuthorizedEnvironmentProcessServiceDispatcher(this._adeleService);
  final AuthorizedEnvironmentProcessService _adeleService;
  final Map<int, _ContractStreamState> _adeleStreams =
      <int, _ContractStreamState>{};
  Future<void> _adeleOrdinaryTail = Future<void>.value();
  final Set<Future<void>> _adeleOperations = <Future<void>>{};
  final Set<Future<void>> _adeleCancellations = <Future<void>>{};
  Future<void>? _adeleCloseFuture;
  bool _adeleClosed = false;
  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0) {
    if (_adeleClosed)
      return Future<Map<String, Object?>>.error(
        StateError('The dispatcher is closed.'),
      );
    return _adeleScheduleOrdinary<Map<String, Object?>>(
      () => _adeleDispatchCore(_adeleRequest0),
    );
  }

  Future<Map<String, Object?>> _adeleDispatchCore(
    Map<Object?, Object?> _adeleRequest0,
  ) async {
    final _adeleRequestId1 = _adeleRequest0['requestId'];
    late final String _adeleMethod2;
    try {
      _adeleMethod2 = _decodeContractEnvelope(_adeleRequest0, 'request');
    } on AdeleProtocolException catch (_adeleError3) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError3.message,
        const {},
      );
    }
    if (!const <String>{}.contains(_adeleMethod2))
      return _contractFailure(
        _adeleRequestId1,
        null,
        const {
              authorizedEnvironmentProcessServiceRunForegroundProcessId,
            }.contains(_adeleMethod2)
            ? 'wrong_method_kind'
            : 'unknown_method',
        const {
              authorizedEnvironmentProcessServiceRunForegroundProcessId,
            }.contains(_adeleMethod2)
            ? 'Streaming method requires stream-open.'
            : 'Unknown method.',
        const {},
      );
    late final Map<Object?, Object?> _adelePayload4;
    try {
      _adelePayload4 = _contractMap(
        _adeleRequest0['payload'],
        'request payload',
      );
    } on AdeleProtocolException catch (_adeleError5) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError5.message,
        const {},
      );
    }
    late final Object? _adeleArguments6;
    try {
      _adeleArguments6 = switch (_adeleMethod2) {
        _ => throw const _ContractUnknownMethod(),
      };
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on AdeleProtocolException catch (_adeleError7) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError7.message,
        const {},
      );
    }
    late final Object? _adeleResult8;
    try {
      _adeleResult8 = await switch (_adeleMethod2) {
        _ => throw const _ContractUnknownMethod(),
      };
    } on EnvironmentFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          environmentFailureTypeId,
          _adeleError9.code,
          _adeleError9.message,
          _contractJsonMap(_adeleError9.details, 'failure details'),
        );
      } on Object {
        return _contractFailure(
          _adeleRequestId1,
          null,
          'backend_contract_violation',
          'The backend violated its generated contract.',
          const {},
        );
      }
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on Object catch (_adeleError10) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'internal_error',
        'The backend request failed unexpectedly.',
        const {},
      );
    }
    try {
      final _adeleEncoded11 = switch (_adeleMethod2) {
        _ => throw const _ContractUnknownMethod(),
      };
      return {
        'kind': 'response',
        'requestId': _adeleRequestId1,
        'ok': true,
        'payload': _adeleEncoded11,
      };
    } on Object {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'backend_contract_violation',
        'The backend violated its generated contract.',
        const {},
      );
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> _adeleCommand0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) {
    final _adeleKind2 = _adeleCommand0['kind'];
    if (_adeleKind2 == 'request') {
      if (_adeleClosed) return Future<void>.value();
      return _adeleScheduleOrdinary<void>(
        () async => _adeleSend1(await _adeleDispatchCore(_adeleCommand0)),
      );
    }
    if (_adeleKind2 == 'streamOpen') {
      if (_adeleClosed) return Future<void>.value();
      final _adeleRequestId3 = _adeleCommand0['requestId'];
      if (_adeleRequestId3 is! int ||
          _adeleStreams.containsKey(_adeleRequestId3)) {
        _adeleSend1(
          _contractStreamFailure(
            _adeleRequestId3,
            null,
            'invalid_request',
            'Malformed stream-open request.',
            const {},
          ),
        );
        return Future<void>.value();
      }
      final _adeleState4 = _ContractStreamState.opening(_adeleRequestId3);
      _adeleStreams[_adeleRequestId3] = _adeleState4;
      return _adeleScheduleOrdinary<void>(
        () => _adeleOpenStream(_adeleState4, _adeleCommand0, _adeleSend1),
      );
    }
    final _adeleRequestId3 = _adeleCommand0['requestId'];
    if (_adeleRequestId3 is! int) return Future<void>.value();
    final _adeleState4 = _adeleStreams[_adeleRequestId3];
    if (_adeleKind2 == 'streamCredit') {
      final _adeleCredit5 = _adeleCommand0['credit'];
      if (_adeleState4 != null && _adeleCredit5 is int && _adeleCredit5 > 0) {
        _adeleState4.credit += _adeleCredit5;
        _adelePump(_adeleState4, _adeleSend1);
      }
      return Future<void>.value();
    }
    if (_adeleKind2 == 'streamCancel')
      return _adeleCancelAndAcknowledge(_adeleRequestId3, _adeleSend1);
    return Future<void>.value();
  }

  Future<T> _adeleScheduleOrdinary<T>(Future<T> Function() _adeleBody0) {
    final Future<T> _adeleResult1 = _adeleOrdinaryTail.then(
      (_) => _adeleBody0(),
    );
    late final Future<void> _adeleSettlement2;
    _adeleSettlement2 = _adeleResult1
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() => _adeleOperations.remove(_adeleSettlement2));
    _adeleOrdinaryTail = _adeleSettlement2;
    _adeleOperations.add(_adeleSettlement2);
    return _adeleResult1;
  }

  Future<void> _adeleOpenStream(
    _ContractStreamState _adeleState0,
    Map<Object?, Object?> _adeleRequest0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    final _adeleRequestId2 = _adeleState0.requestId;
    try {
      if (_adeleState0.done) return;
      late final String _adeleMethod3;
      late final Map<Object?, Object?> _adelePayload4;
      late final List<Object?> _adeleArguments5;
      try {
        _adeleMethod3 = _decodeContractEnvelope(_adeleRequest0, 'streamOpen');
        if (!const {
          authorizedEnvironmentProcessServiceRunForegroundProcessId,
        }.contains(_adeleMethod3)) {
          final _adeleWrongKind6 = const <String>{}.contains(_adeleMethod3);
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              null,
              _adeleWrongKind6 ? 'wrong_method_kind' : 'unknown_method',
              _adeleWrongKind6
                  ? 'Unary method requires request.'
                  : 'Unknown method.',
              const {},
            ),
          );
          return;
        }
        _adelePayload4 = _contractMap(
          _adeleRequest0['payload'],
          'request payload',
        );
        _adeleArguments5 = switch (_adeleMethod3) {
          authorizedEnvironmentProcessServiceRunForegroundProcessId => (() {
            _contractFields(_adelePayload4, const {
              'request',
            }, 'runForegroundProcess payload');
            return <Object?>[
              _decodeEnvironmentForegroundProcessRequest(
                _adelePayload4['request'],
              ),
            ];
          })(),
          _ => throw const _ContractUnknownMethod(),
        };
      } on AdeleProtocolException catch (_adeleError7) {
        _adeleFinish(
          _adeleState0,
          _adeleSend1,
          _contractStreamFailure(
            _adeleRequestId2,
            null,
            'invalid_request',
            _adeleError7.message,
            const {},
          ),
        );
        return;
      }
      try {
        final Stream<Object?> _adeleSource8 = switch (_adeleMethod3) {
          authorizedEnvironmentProcessServiceRunForegroundProcessId =>
            this._adeleService
                .runForegroundProcess(
                  _adeleArguments5[0] as EnvironmentForegroundProcessRequest,
                )
                .map<Object?>((Object? _adeleItem) => _adeleItem),
          _ => throw const _ContractUnknownMethod(),
        };
        if (_adeleState0.done) {
          await AdeleStreamIterator<Object?>(_adeleSource8).cancel();
          return;
        }
        _adeleState0.method = _adeleMethod3;
        _adeleState0.iterator = AdeleStreamIterator<Object?>(_adeleSource8);
        _adelePump(_adeleState0, _adeleSend1);
      } on EnvironmentFailure catch (_adeleError9) {
        try {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              environmentFailureTypeId,
              _adeleError9.code,
              _adeleError9.message,
              _contractJsonMap(_adeleError9.details, 'failure details'),
            ),
          );
        } on Object {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              null,
              'backend_contract_violation',
              'The backend violated its generated contract.',
              const {},
            ),
          );
        }
      } on TypeError {
        _adeleFinish(
          _adeleState0,
          _adeleSend1,
          _contractStreamFailure(
            _adeleRequestId2,
            null,
            'backend_contract_violation',
            'The backend violated its generated contract.',
            const {},
          ),
        );
      } on Object {
        _adeleFinish(
          _adeleState0,
          _adeleSend1,
          _contractStreamFailure(
            _adeleRequestId2,
            null,
            'internal_error',
            'The backend stream failed unexpectedly.',
            const {},
          ),
        );
      }
    } finally {
      if (!_adeleState0.openingSettled.isCompleted)
        _adeleState0.openingSettled.complete();
    }
  }

  Future<void> _adelePump(
    _ContractStreamState _adeleState0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    final _adeleIterator2 = _adeleState0.iterator;
    if (_adeleState0.pumping || _adeleState0.done || _adeleIterator2 == null)
      return;
    _adeleState0.pumping = true;
    try {
      while (!_adeleState0.done && _adeleState0.credit > 0) {
        _adeleState0.credit--;
        late final bool _adeleHasItem2;
        try {
          _adeleHasItem2 = await _adeleIterator2.moveNext();
        } on EnvironmentFailure catch (_adeleError3) {
          try {
            _adeleFinish(
              _adeleState0,
              _adeleSend1,
              _contractStreamFailure(
                _adeleState0.requestId,
                environmentFailureTypeId,
                _adeleError3.code,
                _adeleError3.message,
                _contractJsonMap(_adeleError3.details, 'failure details'),
              ),
            );
          } on Object {
            _adeleFinish(
              _adeleState0,
              _adeleSend1,
              _contractStreamFailure(
                _adeleState0.requestId,
                null,
                'backend_contract_violation',
                'The backend violated its generated contract.',
                const {},
              ),
            );
          }
          return;
        } on TypeError {
          _adeleFailAndCancel(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleState0.requestId,
              null,
              'backend_contract_violation',
              'The backend violated its generated contract.',
              const {},
            ),
          );
          return;
        } on Object {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleState0.requestId,
              null,
              'internal_error',
              'The backend stream failed unexpectedly.',
              const {},
            ),
          );
          return;
        }
        if (_adeleState0.done ||
            _adeleStreams[_adeleState0.requestId] != _adeleState0)
          return;
        if (!_adeleHasItem2) {
          _adeleFinish(_adeleState0, _adeleSend1, {
            'kind': 'streamDone',
            'requestId': _adeleState0.requestId,
          });
          return;
        }
        try {
          final _adeleEncoded4 = switch (_adeleState0.method) {
            authorizedEnvironmentProcessServiceRunForegroundProcessId =>
              _encodeEnvironmentProcessEvent(
                (_adeleIterator2.current as EnvironmentProcessEvent),
              ),
            _ => throw const _ContractUnknownMethod(),
          };
          _adeleSend1({
            'kind': 'streamItem',
            'requestId': _adeleState0.requestId,
            'payload': _adeleEncoded4,
          });
        } on Object {
          _adeleFailAndCancel(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleState0.requestId,
              null,
              'backend_contract_violation',
              'The backend violated its generated contract.',
              const {},
            ),
          );
          return;
        }
      }
    } finally {
      _adeleState0.pumping = false;
      if (!_adeleState0.done &&
          _adeleState0.credit > 0 &&
          _adeleState0.iterator != null)
        _adelePump(_adeleState0, _adeleSend1);
    }
  }

  void _adeleFinish(
    _ContractStreamState _adeleState0,
    void Function(Map<String, Object?>) _adeleSend1,
    Map<String, Object?> _adeleTerminal2,
  ) {
    if (_adeleState0.done ||
        _adeleStreams.remove(_adeleState0.requestId) != _adeleState0)
      return;
    _adeleState0.done = true;
    _adeleSend1(_adeleTerminal2);
  }

  void _adeleFailAndCancel(
    _ContractStreamState _adeleState0,
    void Function(Map<String, Object?>) _adeleSend1,
    Map<String, Object?> _adeleTerminal2,
  ) {
    if (_adeleState0.done ||
        _adeleStreams.remove(_adeleState0.requestId) != _adeleState0)
      return;
    _adeleState0.done = true;
    _adeleTrackCancellation(
      _adeleState0,
      onSettled: () => _adeleSend1(_adeleTerminal2),
    );
  }

  Future<void> _adeleCancelAndAcknowledge(
    int _adeleRequestId0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    if (await _adeleCancel(_adeleRequestId0))
      _adeleSend1({'kind': 'streamCancelled', 'requestId': _adeleRequestId0});
  }

  Future<void> _adeleTrackCancellation(
    _ContractStreamState _adeleState0, {
    void Function()? onSettled,
  }) {
    late final Future<void> _adeleCancellation1;
    _adeleCancellation1 =
        (() async {
              await _adeleState0.openingSettled.future;
              try {
                await _adeleState0.iterator?.cancel();
              } on Object {
                return;
              }
            })()
            .then<void>((_) => onSettled?.call())
            .whenComplete(
              () => _adeleCancellations.remove(_adeleCancellation1),
            );
    _adeleCancellations.add(_adeleCancellation1);
    return _adeleCancellation1;
  }

  Future<bool> _adeleCancel(int _adeleRequestId0) {
    final _adeleState1 = _adeleStreams.remove(_adeleRequestId0);
    if (_adeleState1 == null || _adeleState1.done)
      return Future<bool>.value(false);
    _adeleState1.done = true;
    return _adeleTrackCancellation(_adeleState1).then((_) => true);
  }

  @override
  Future<void> close() => _adeleCloseFuture ??= _adeleClose();
  Future<void> _adeleClose() async {
    _adeleClosed = true;
    final _adeleIds0 = _adeleStreams.keys.toList(growable: false);
    await Future.wait<bool>(_adeleIds0.map(_adeleCancel));
    await Future.wait<void>(_adeleOperations.toList(growable: false));
    await Future.wait<void>(_adeleCancellations.toList(growable: false));
  }
}

const String authorizedEnvironmentReadServiceId = 'authorizedEnvironmentRead';
const String authorizedEnvironmentReadServiceAuthorityId =
    'authorizedEnvironmentRead.authority';
const String authorizedEnvironmentReadServiceReadDirectoryId =
    'authorizedEnvironmentRead.readDirectory';
const String authorizedEnvironmentReadServiceReadFileId =
    'authorizedEnvironmentRead.readFile';

final class AuthorizedEnvironmentReadServiceClient
    implements AuthorizedEnvironmentReadService {
  const AuthorizedEnvironmentReadServiceClient(
    AdeleRequestChannel _adeleChannel,
  ) : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    try {
      return _decodeAuthorizedEnvironmentIdentity(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceAuthorityId,
          <String, Object?>{},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError52) {
      switch (_adeleError52.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError52.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError52.code,
              message: _adeleError52.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    try {
      return _decodeEnvironmentDirectoryListing(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceReadDirectoryId,
          <String, Object?>{'relativePath': relativePath},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError55) {
      switch (_adeleError55.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError55.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError55.code,
              message: _adeleError55.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    try {
      return _decodeEnvironmentTextFile(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceReadFileId,
          <String, Object?>{'relativePath': relativePath},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError60) {
      switch (_adeleError60.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError60.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError60.code,
              message: _adeleError60.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class AuthorizedEnvironmentReadServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class AuthorizedEnvironmentReadServiceDispatcher
    implements AuthorizedEnvironmentReadServiceRequestDispatcher {
  AuthorizedEnvironmentReadServiceDispatcher(this._adeleService);
  final AuthorizedEnvironmentReadService _adeleService;
  Future<void> _adeleOrdinaryTail = Future<void>.value();
  final Set<Future<void>> _adeleOperations = <Future<void>>{};
  Future<void>? _adeleCloseFuture;
  bool _adeleClosed = false;
  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0) {
    if (_adeleClosed)
      return Future<Map<String, Object?>>.error(
        StateError('The dispatcher is closed.'),
      );
    return _adeleScheduleOrdinary<Map<String, Object?>>(
      () => _adeleDispatchCore(_adeleRequest0),
    );
  }

  Future<Map<String, Object?>> _adeleDispatchCore(
    Map<Object?, Object?> _adeleRequest0,
  ) async {
    final _adeleRequestId1 = _adeleRequest0['requestId'];
    late final String _adeleMethod2;
    try {
      _adeleMethod2 = _decodeContractEnvelope(_adeleRequest0, 'request');
    } on AdeleProtocolException catch (_adeleError3) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError3.message,
        const {},
      );
    }
    if (!const {
      authorizedEnvironmentReadServiceAuthorityId,
      authorizedEnvironmentReadServiceReadDirectoryId,
      authorizedEnvironmentReadServiceReadFileId,
    }.contains(_adeleMethod2))
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    late final Map<Object?, Object?> _adelePayload4;
    try {
      _adelePayload4 = _contractMap(
        _adeleRequest0['payload'],
        'request payload',
      );
    } on AdeleProtocolException catch (_adeleError5) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError5.message,
        const {},
      );
    }
    late final Object? _adeleArguments6;
    try {
      _adeleArguments6 = switch (_adeleMethod2) {
        authorizedEnvironmentReadServiceAuthorityId => (() {
          _contractFields(_adelePayload4, const {}, 'authority payload');
          return <Object?>[];
        })(),
        authorizedEnvironmentReadServiceReadDirectoryId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
          }, 'readDirectory payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
          ];
        })(),
        authorizedEnvironmentReadServiceReadFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
          }, 'readFile payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
          ];
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on AdeleProtocolException catch (_adeleError7) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError7.message,
        const {},
      );
    }
    late final Object? _adeleResult8;
    try {
      _adeleResult8 = await switch (_adeleMethod2) {
        authorizedEnvironmentReadServiceAuthorityId => (() async {
          return await this._adeleService.authority();
        })(),
        authorizedEnvironmentReadServiceReadDirectoryId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.readDirectory(
            _adeleValues0[0] as String,
          );
        })(),
        authorizedEnvironmentReadServiceReadFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.readFile(_adeleValues0[0] as String);
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on EnvironmentFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          environmentFailureTypeId,
          _adeleError9.code,
          _adeleError9.message,
          _contractJsonMap(_adeleError9.details, 'failure details'),
        );
      } on Object {
        return _contractFailure(
          _adeleRequestId1,
          null,
          'backend_contract_violation',
          'The backend violated its generated contract.',
          const {},
        );
      }
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on Object catch (_adeleError10) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'internal_error',
        'The backend request failed unexpectedly.',
        const {},
      );
    }
    try {
      final _adeleEncoded11 = switch (_adeleMethod2) {
        authorizedEnvironmentReadServiceAuthorityId =>
          _encodeAuthorizedEnvironmentIdentity(
            (_adeleResult8 as AuthorizedEnvironmentIdentity),
          ),
        authorizedEnvironmentReadServiceReadDirectoryId =>
          _encodeEnvironmentDirectoryListing(
            (_adeleResult8 as EnvironmentDirectoryListing),
          ),
        authorizedEnvironmentReadServiceReadFileId =>
          _encodeEnvironmentTextFile((_adeleResult8 as EnvironmentTextFile)),
        _ => throw const _ContractUnknownMethod(),
      };
      return {
        'kind': 'response',
        'requestId': _adeleRequestId1,
        'ok': true,
        'payload': _adeleEncoded11,
      };
    } on Object {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'backend_contract_violation',
        'The backend violated its generated contract.',
        const {},
      );
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> _adeleCommand0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) {
    if (_adeleClosed) return Future<void>.value();
    return _adeleScheduleOrdinary<void>(
      () async => _adeleSend1(await _adeleDispatchCore(_adeleCommand0)),
    );
  }

  Future<T> _adeleScheduleOrdinary<T>(Future<T> Function() _adeleBody0) {
    final Future<T> _adeleResult1 = _adeleOrdinaryTail.then(
      (_) => _adeleBody0(),
    );
    late final Future<void> _adeleSettlement2;
    _adeleSettlement2 = _adeleResult1
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() => _adeleOperations.remove(_adeleSettlement2));
    _adeleOrdinaryTail = _adeleSettlement2;
    _adeleOperations.add(_adeleSettlement2);
    return _adeleResult1;
  }

  @override
  Future<void> close() => _adeleCloseFuture ??= _adeleClose();
  Future<void> _adeleClose() async {
    _adeleClosed = true;
    await Future.wait<void>(_adeleOperations.toList(growable: false));
  }
}

const String environmentProviderServiceId = 'environment';
const String environmentProviderServiceCreateTextFileId =
    'environment.createTextFile';
const String environmentProviderServiceDeleteExistingTextFileId =
    'environment.deleteExistingTextFile';
const String environmentProviderServiceEstablishId = 'environment.establish';
const String environmentProviderServiceReadDirectoryId =
    'environment.readDirectory';
const String environmentProviderServiceReadFileId = 'environment.readFile';
const String environmentProviderServiceReplaceExistingTextFileId =
    'environment.replaceExistingTextFile';
const String environmentProviderServiceRestoreId = 'environment.restore';
const String environmentProviderServiceRunForegroundProcessId =
    'environment.runForegroundProcess';

final class EnvironmentProviderServiceClient
    implements EnvironmentProviderService {
  const EnvironmentProviderServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String environmentId,
    String relativePath,
    String text,
  ) async {
    try {
      return _decodeEnvironmentTextFileCreation(
        await this._adeleChannel.request(
          environmentProviderServiceCreateTextFileId,
          <String, Object?>{
            'environmentId': environmentId,
            'relativePath': relativePath,
            'text': text,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError75) {
      switch (_adeleError75.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError75.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError75.code,
              message: _adeleError75.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<void> deleteExistingTextFile(
    String environmentId,
    String relativePath,
    String expectedRevision,
  ) async {
    try {
      final _adeleResponse91 = await this._adeleChannel.request(
        environmentProviderServiceDeleteExistingTextFileId,
        <String, Object?>{
          'environmentId': environmentId,
          'relativePath': relativePath,
          'expectedRevision': expectedRevision,
        },
      );
      _contractVoid(_adeleResponse91, 'deleteExistingTextFile');
      return;
    } on AdeleRemoteFailure catch (_adeleError84) {
      switch (_adeleError84.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError84.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError84.code,
              message: _adeleError84.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentProviderResult> establish(
    EnvironmentTransportContext context,
  ) async {
    try {
      return _decodeEnvironmentProviderResult(
        await this._adeleChannel.request(
          environmentProviderServiceEstablishId,
          <String, Object?>{
            'context': _encodeEnvironmentTransportContext(context),
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError92) {
      switch (_adeleError92.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError92.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError92.code,
              message: _adeleError92.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(
    String environmentId,
    String relativePath,
  ) async {
    try {
      return _decodeEnvironmentDirectoryListing(
        await this._adeleChannel.request(
          environmentProviderServiceReadDirectoryId,
          <String, Object?>{
            'environmentId': environmentId,
            'relativePath': relativePath,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError97) {
      switch (_adeleError97.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError97.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError97.code,
              message: _adeleError97.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentTextFile> readFile(
    String environmentId,
    String relativePath,
  ) async {
    try {
      return _decodeEnvironmentTextFile(
        await this._adeleChannel.request(
          environmentProviderServiceReadFileId,
          <String, Object?>{
            'environmentId': environmentId,
            'relativePath': relativePath,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError104) {
      switch (_adeleError104.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError104.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError104.code,
              message: _adeleError104.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String environmentId,
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    try {
      return _decodeEnvironmentTextFileReplacement(
        await this._adeleChannel.request(
          environmentProviderServiceReplaceExistingTextFileId,
          <String, Object?>{
            'environmentId': environmentId,
            'relativePath': relativePath,
            'replacementText': replacementText,
            'expectedRevision': expectedRevision,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError111) {
      switch (_adeleError111.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError111.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError111.code,
              message: _adeleError111.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentProviderResult> restore(
    EnvironmentTransportContext context,
  ) async {
    try {
      return _decodeEnvironmentProviderResult(
        await this._adeleChannel.request(
          environmentProviderServiceRestoreId,
          <String, Object?>{
            'context': _encodeEnvironmentTransportContext(context),
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError122) {
      switch (_adeleError122.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError122.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError122.code,
              message: _adeleError122.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    String environmentId,
    EnvironmentForegroundProcessRequest request,
  ) => AdeleLazyStream<EnvironmentProcessEvent>((
    _adeleOnData0,
    _adeleOnError1,
    _adeleOnDone2,
    _adeleCancelOnError3,
  ) {
    final _adeleStreamChannel4 = this._adeleChannel;
    if (_adeleStreamChannel4 is! AdeleStreamChannel)
      throw StateError('This generated method requires an AdeleStreamChannel.');
    final _adeleRaw128 = _adeleStreamChannel4.stream(
      environmentProviderServiceRunForegroundProcessId,
      <String, Object?>{
        'environmentId': environmentId,
        'request': _encodeEnvironmentForegroundProcessRequest(request),
      },
    );
    return adeleDecodedStream<EnvironmentProcessEvent>(
      _adeleRaw128,
      (Object? _adeleItem5) => _decodeEnvironmentProcessEvent(_adeleItem5),
      (Object _adeleError127) {
        if (_adeleError127 is AdeleRemoteFailure) {
          switch (_adeleError127.declaredFailureType) {
            case environmentFailureTypeId:
              final _adeleDetails8 = _contractJsonMap(
                _adeleError127.details,
                'failure details',
              );
              throw _contractConstruct(
                'EnvironmentFailure',
                () => EnvironmentFailure(
                  code: _adeleError127.code,
                  message: _adeleError127.message,
                  details: _adeleDetails8,
                ),
              );
            default:
              break;
          }
        }
        return _adeleError127;
      },
    ).listen(
      _adeleOnData0,
      onError: _adeleOnError1,
      onDone: _adeleOnDone2,
      cancelOnError: _adeleCancelOnError3,
    );
  });
}

abstract interface class EnvironmentProviderServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class EnvironmentProviderServiceDispatcher
    implements EnvironmentProviderServiceRequestDispatcher {
  EnvironmentProviderServiceDispatcher(this._adeleService);
  final EnvironmentProviderService _adeleService;
  final Map<int, _ContractStreamState> _adeleStreams =
      <int, _ContractStreamState>{};
  Future<void> _adeleOrdinaryTail = Future<void>.value();
  final Set<Future<void>> _adeleOperations = <Future<void>>{};
  final Set<Future<void>> _adeleCancellations = <Future<void>>{};
  Future<void>? _adeleCloseFuture;
  bool _adeleClosed = false;
  @override
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0) {
    if (_adeleClosed)
      return Future<Map<String, Object?>>.error(
        StateError('The dispatcher is closed.'),
      );
    return _adeleScheduleOrdinary<Map<String, Object?>>(
      () => _adeleDispatchCore(_adeleRequest0),
    );
  }

  Future<Map<String, Object?>> _adeleDispatchCore(
    Map<Object?, Object?> _adeleRequest0,
  ) async {
    final _adeleRequestId1 = _adeleRequest0['requestId'];
    late final String _adeleMethod2;
    try {
      _adeleMethod2 = _decodeContractEnvelope(_adeleRequest0, 'request');
    } on AdeleProtocolException catch (_adeleError3) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError3.message,
        const {},
      );
    }
    if (!const {
      environmentProviderServiceCreateTextFileId,
      environmentProviderServiceDeleteExistingTextFileId,
      environmentProviderServiceEstablishId,
      environmentProviderServiceReadDirectoryId,
      environmentProviderServiceReadFileId,
      environmentProviderServiceReplaceExistingTextFileId,
      environmentProviderServiceRestoreId,
    }.contains(_adeleMethod2))
      return _contractFailure(
        _adeleRequestId1,
        null,
        const {
              environmentProviderServiceRunForegroundProcessId,
            }.contains(_adeleMethod2)
            ? 'wrong_method_kind'
            : 'unknown_method',
        const {
              environmentProviderServiceRunForegroundProcessId,
            }.contains(_adeleMethod2)
            ? 'Streaming method requires stream-open.'
            : 'Unknown method.',
        const {},
      );
    late final Map<Object?, Object?> _adelePayload4;
    try {
      _adelePayload4 = _contractMap(
        _adeleRequest0['payload'],
        'request payload',
      );
    } on AdeleProtocolException catch (_adeleError5) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError5.message,
        const {},
      );
    }
    late final Object? _adeleArguments6;
    try {
      _adeleArguments6 = switch (_adeleMethod2) {
        environmentProviderServiceCreateTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'environmentId',
            'relativePath',
            'text',
          }, 'createTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['environmentId'], 'environmentId'),
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(_adelePayload4['text'], 'text'),
          ];
        })(),
        environmentProviderServiceDeleteExistingTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'environmentId',
            'relativePath',
            'expectedRevision',
          }, 'deleteExistingTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['environmentId'], 'environmentId'),
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(
              _adelePayload4['expectedRevision'],
              'expectedRevision',
            ),
          ];
        })(),
        environmentProviderServiceEstablishId => (() {
          _contractFields(_adelePayload4, const {
            'context',
          }, 'establish payload');
          return <Object?>[
            _decodeEnvironmentTransportContext(_adelePayload4['context']),
          ];
        })(),
        environmentProviderServiceReadDirectoryId => (() {
          _contractFields(_adelePayload4, const {
            'environmentId',
            'relativePath',
          }, 'readDirectory payload');
          return <Object?>[
            _contractString(_adelePayload4['environmentId'], 'environmentId'),
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
          ];
        })(),
        environmentProviderServiceReadFileId => (() {
          _contractFields(_adelePayload4, const {
            'environmentId',
            'relativePath',
          }, 'readFile payload');
          return <Object?>[
            _contractString(_adelePayload4['environmentId'], 'environmentId'),
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
          ];
        })(),
        environmentProviderServiceReplaceExistingTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'environmentId',
            'relativePath',
            'replacementText',
            'expectedRevision',
          }, 'replaceExistingTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['environmentId'], 'environmentId'),
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(
              _adelePayload4['replacementText'],
              'replacementText',
            ),
            _contractString(
              _adelePayload4['expectedRevision'],
              'expectedRevision',
            ),
          ];
        })(),
        environmentProviderServiceRestoreId => (() {
          _contractFields(_adelePayload4, const {'context'}, 'restore payload');
          return <Object?>[
            _decodeEnvironmentTransportContext(_adelePayload4['context']),
          ];
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on AdeleProtocolException catch (_adeleError7) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError7.message,
        const {},
      );
    }
    late final Object? _adeleResult8;
    try {
      _adeleResult8 = await switch (_adeleMethod2) {
        environmentProviderServiceCreateTextFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.createTextFile(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
            _adeleValues0[2] as String,
          );
        })(),
        environmentProviderServiceDeleteExistingTextFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          await this._adeleService.deleteExistingTextFile(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
            _adeleValues0[2] as String,
          );
          return null;
        })(),
        environmentProviderServiceEstablishId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.establish(
            _adeleValues0[0] as EnvironmentTransportContext,
          );
        })(),
        environmentProviderServiceReadDirectoryId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.readDirectory(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
          );
        })(),
        environmentProviderServiceReadFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.readFile(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
          );
        })(),
        environmentProviderServiceReplaceExistingTextFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.replaceExistingTextFile(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
            _adeleValues0[2] as String,
            _adeleValues0[3] as String,
          );
        })(),
        environmentProviderServiceRestoreId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.restore(
            _adeleValues0[0] as EnvironmentTransportContext,
          );
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on EnvironmentFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          environmentFailureTypeId,
          _adeleError9.code,
          _adeleError9.message,
          _contractJsonMap(_adeleError9.details, 'failure details'),
        );
      } on Object {
        return _contractFailure(
          _adeleRequestId1,
          null,
          'backend_contract_violation',
          'The backend violated its generated contract.',
          const {},
        );
      }
    } on _ContractUnknownMethod {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'unknown_method',
        'Unknown method.',
        const {},
      );
    } on Object catch (_adeleError10) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'internal_error',
        'The backend request failed unexpectedly.',
        const {},
      );
    }
    try {
      final _adeleEncoded11 = switch (_adeleMethod2) {
        environmentProviderServiceCreateTextFileId =>
          _encodeEnvironmentTextFileCreation(
            (_adeleResult8 as EnvironmentTextFileCreation),
          ),
        environmentProviderServiceDeleteExistingTextFileId => null,
        environmentProviderServiceEstablishId =>
          _encodeEnvironmentProviderResult(
            (_adeleResult8 as EnvironmentProviderResult),
          ),
        environmentProviderServiceReadDirectoryId =>
          _encodeEnvironmentDirectoryListing(
            (_adeleResult8 as EnvironmentDirectoryListing),
          ),
        environmentProviderServiceReadFileId => _encodeEnvironmentTextFile(
          (_adeleResult8 as EnvironmentTextFile),
        ),
        environmentProviderServiceReplaceExistingTextFileId =>
          _encodeEnvironmentTextFileReplacement(
            (_adeleResult8 as EnvironmentTextFileReplacement),
          ),
        environmentProviderServiceRestoreId => _encodeEnvironmentProviderResult(
          (_adeleResult8 as EnvironmentProviderResult),
        ),
        _ => throw const _ContractUnknownMethod(),
      };
      return {
        'kind': 'response',
        'requestId': _adeleRequestId1,
        'ok': true,
        'payload': _adeleEncoded11,
      };
    } on Object {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'backend_contract_violation',
        'The backend violated its generated contract.',
        const {},
      );
    }
  }

  @override
  Future<void> handle(
    Map<Object?, Object?> _adeleCommand0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) {
    final _adeleKind2 = _adeleCommand0['kind'];
    if (_adeleKind2 == 'request') {
      if (_adeleClosed) return Future<void>.value();
      return _adeleScheduleOrdinary<void>(
        () async => _adeleSend1(await _adeleDispatchCore(_adeleCommand0)),
      );
    }
    if (_adeleKind2 == 'streamOpen') {
      if (_adeleClosed) return Future<void>.value();
      final _adeleRequestId3 = _adeleCommand0['requestId'];
      if (_adeleRequestId3 is! int ||
          _adeleStreams.containsKey(_adeleRequestId3)) {
        _adeleSend1(
          _contractStreamFailure(
            _adeleRequestId3,
            null,
            'invalid_request',
            'Malformed stream-open request.',
            const {},
          ),
        );
        return Future<void>.value();
      }
      final _adeleState4 = _ContractStreamState.opening(_adeleRequestId3);
      _adeleStreams[_adeleRequestId3] = _adeleState4;
      return _adeleScheduleOrdinary<void>(
        () => _adeleOpenStream(_adeleState4, _adeleCommand0, _adeleSend1),
      );
    }
    final _adeleRequestId3 = _adeleCommand0['requestId'];
    if (_adeleRequestId3 is! int) return Future<void>.value();
    final _adeleState4 = _adeleStreams[_adeleRequestId3];
    if (_adeleKind2 == 'streamCredit') {
      final _adeleCredit5 = _adeleCommand0['credit'];
      if (_adeleState4 != null && _adeleCredit5 is int && _adeleCredit5 > 0) {
        _adeleState4.credit += _adeleCredit5;
        _adelePump(_adeleState4, _adeleSend1);
      }
      return Future<void>.value();
    }
    if (_adeleKind2 == 'streamCancel')
      return _adeleCancelAndAcknowledge(_adeleRequestId3, _adeleSend1);
    return Future<void>.value();
  }

  Future<T> _adeleScheduleOrdinary<T>(Future<T> Function() _adeleBody0) {
    final Future<T> _adeleResult1 = _adeleOrdinaryTail.then(
      (_) => _adeleBody0(),
    );
    late final Future<void> _adeleSettlement2;
    _adeleSettlement2 = _adeleResult1
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() => _adeleOperations.remove(_adeleSettlement2));
    _adeleOrdinaryTail = _adeleSettlement2;
    _adeleOperations.add(_adeleSettlement2);
    return _adeleResult1;
  }

  Future<void> _adeleOpenStream(
    _ContractStreamState _adeleState0,
    Map<Object?, Object?> _adeleRequest0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    final _adeleRequestId2 = _adeleState0.requestId;
    try {
      if (_adeleState0.done) return;
      late final String _adeleMethod3;
      late final Map<Object?, Object?> _adelePayload4;
      late final List<Object?> _adeleArguments5;
      try {
        _adeleMethod3 = _decodeContractEnvelope(_adeleRequest0, 'streamOpen');
        if (!const {
          environmentProviderServiceRunForegroundProcessId,
        }.contains(_adeleMethod3)) {
          final _adeleWrongKind6 = const {
            environmentProviderServiceCreateTextFileId,
            environmentProviderServiceDeleteExistingTextFileId,
            environmentProviderServiceEstablishId,
            environmentProviderServiceReadDirectoryId,
            environmentProviderServiceReadFileId,
            environmentProviderServiceReplaceExistingTextFileId,
            environmentProviderServiceRestoreId,
          }.contains(_adeleMethod3);
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              null,
              _adeleWrongKind6 ? 'wrong_method_kind' : 'unknown_method',
              _adeleWrongKind6
                  ? 'Unary method requires request.'
                  : 'Unknown method.',
              const {},
            ),
          );
          return;
        }
        _adelePayload4 = _contractMap(
          _adeleRequest0['payload'],
          'request payload',
        );
        _adeleArguments5 = switch (_adeleMethod3) {
          environmentProviderServiceRunForegroundProcessId => (() {
            _contractFields(_adelePayload4, const {
              'environmentId',
              'request',
            }, 'runForegroundProcess payload');
            return <Object?>[
              _contractString(_adelePayload4['environmentId'], 'environmentId'),
              _decodeEnvironmentForegroundProcessRequest(
                _adelePayload4['request'],
              ),
            ];
          })(),
          _ => throw const _ContractUnknownMethod(),
        };
      } on AdeleProtocolException catch (_adeleError7) {
        _adeleFinish(
          _adeleState0,
          _adeleSend1,
          _contractStreamFailure(
            _adeleRequestId2,
            null,
            'invalid_request',
            _adeleError7.message,
            const {},
          ),
        );
        return;
      }
      try {
        final Stream<Object?> _adeleSource8 = switch (_adeleMethod3) {
          environmentProviderServiceRunForegroundProcessId =>
            this._adeleService
                .runForegroundProcess(
                  _adeleArguments5[0] as String,
                  _adeleArguments5[1] as EnvironmentForegroundProcessRequest,
                )
                .map<Object?>((Object? _adeleItem) => _adeleItem),
          _ => throw const _ContractUnknownMethod(),
        };
        if (_adeleState0.done) {
          await AdeleStreamIterator<Object?>(_adeleSource8).cancel();
          return;
        }
        _adeleState0.method = _adeleMethod3;
        _adeleState0.iterator = AdeleStreamIterator<Object?>(_adeleSource8);
        _adelePump(_adeleState0, _adeleSend1);
      } on EnvironmentFailure catch (_adeleError9) {
        try {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              environmentFailureTypeId,
              _adeleError9.code,
              _adeleError9.message,
              _contractJsonMap(_adeleError9.details, 'failure details'),
            ),
          );
        } on Object {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              null,
              'backend_contract_violation',
              'The backend violated its generated contract.',
              const {},
            ),
          );
        }
      } on TypeError {
        _adeleFinish(
          _adeleState0,
          _adeleSend1,
          _contractStreamFailure(
            _adeleRequestId2,
            null,
            'backend_contract_violation',
            'The backend violated its generated contract.',
            const {},
          ),
        );
      } on Object {
        _adeleFinish(
          _adeleState0,
          _adeleSend1,
          _contractStreamFailure(
            _adeleRequestId2,
            null,
            'internal_error',
            'The backend stream failed unexpectedly.',
            const {},
          ),
        );
      }
    } finally {
      if (!_adeleState0.openingSettled.isCompleted)
        _adeleState0.openingSettled.complete();
    }
  }

  Future<void> _adelePump(
    _ContractStreamState _adeleState0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    final _adeleIterator2 = _adeleState0.iterator;
    if (_adeleState0.pumping || _adeleState0.done || _adeleIterator2 == null)
      return;
    _adeleState0.pumping = true;
    try {
      while (!_adeleState0.done && _adeleState0.credit > 0) {
        _adeleState0.credit--;
        late final bool _adeleHasItem2;
        try {
          _adeleHasItem2 = await _adeleIterator2.moveNext();
        } on EnvironmentFailure catch (_adeleError3) {
          try {
            _adeleFinish(
              _adeleState0,
              _adeleSend1,
              _contractStreamFailure(
                _adeleState0.requestId,
                environmentFailureTypeId,
                _adeleError3.code,
                _adeleError3.message,
                _contractJsonMap(_adeleError3.details, 'failure details'),
              ),
            );
          } on Object {
            _adeleFinish(
              _adeleState0,
              _adeleSend1,
              _contractStreamFailure(
                _adeleState0.requestId,
                null,
                'backend_contract_violation',
                'The backend violated its generated contract.',
                const {},
              ),
            );
          }
          return;
        } on TypeError {
          _adeleFailAndCancel(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleState0.requestId,
              null,
              'backend_contract_violation',
              'The backend violated its generated contract.',
              const {},
            ),
          );
          return;
        } on Object {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleState0.requestId,
              null,
              'internal_error',
              'The backend stream failed unexpectedly.',
              const {},
            ),
          );
          return;
        }
        if (_adeleState0.done ||
            _adeleStreams[_adeleState0.requestId] != _adeleState0)
          return;
        if (!_adeleHasItem2) {
          _adeleFinish(_adeleState0, _adeleSend1, {
            'kind': 'streamDone',
            'requestId': _adeleState0.requestId,
          });
          return;
        }
        try {
          final _adeleEncoded4 = switch (_adeleState0.method) {
            environmentProviderServiceRunForegroundProcessId =>
              _encodeEnvironmentProcessEvent(
                (_adeleIterator2.current as EnvironmentProcessEvent),
              ),
            _ => throw const _ContractUnknownMethod(),
          };
          _adeleSend1({
            'kind': 'streamItem',
            'requestId': _adeleState0.requestId,
            'payload': _adeleEncoded4,
          });
        } on Object {
          _adeleFailAndCancel(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleState0.requestId,
              null,
              'backend_contract_violation',
              'The backend violated its generated contract.',
              const {},
            ),
          );
          return;
        }
      }
    } finally {
      _adeleState0.pumping = false;
      if (!_adeleState0.done &&
          _adeleState0.credit > 0 &&
          _adeleState0.iterator != null)
        _adelePump(_adeleState0, _adeleSend1);
    }
  }

  void _adeleFinish(
    _ContractStreamState _adeleState0,
    void Function(Map<String, Object?>) _adeleSend1,
    Map<String, Object?> _adeleTerminal2,
  ) {
    if (_adeleState0.done ||
        _adeleStreams.remove(_adeleState0.requestId) != _adeleState0)
      return;
    _adeleState0.done = true;
    _adeleSend1(_adeleTerminal2);
  }

  void _adeleFailAndCancel(
    _ContractStreamState _adeleState0,
    void Function(Map<String, Object?>) _adeleSend1,
    Map<String, Object?> _adeleTerminal2,
  ) {
    if (_adeleState0.done ||
        _adeleStreams.remove(_adeleState0.requestId) != _adeleState0)
      return;
    _adeleState0.done = true;
    _adeleTrackCancellation(
      _adeleState0,
      onSettled: () => _adeleSend1(_adeleTerminal2),
    );
  }

  Future<void> _adeleCancelAndAcknowledge(
    int _adeleRequestId0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    if (await _adeleCancel(_adeleRequestId0))
      _adeleSend1({'kind': 'streamCancelled', 'requestId': _adeleRequestId0});
  }

  Future<void> _adeleTrackCancellation(
    _ContractStreamState _adeleState0, {
    void Function()? onSettled,
  }) {
    late final Future<void> _adeleCancellation1;
    _adeleCancellation1 =
        (() async {
              await _adeleState0.openingSettled.future;
              try {
                await _adeleState0.iterator?.cancel();
              } on Object {
                return;
              }
            })()
            .then<void>((_) => onSettled?.call())
            .whenComplete(
              () => _adeleCancellations.remove(_adeleCancellation1),
            );
    _adeleCancellations.add(_adeleCancellation1);
    return _adeleCancellation1;
  }

  Future<bool> _adeleCancel(int _adeleRequestId0) {
    final _adeleState1 = _adeleStreams.remove(_adeleRequestId0);
    if (_adeleState1 == null || _adeleState1.done)
      return Future<bool>.value(false);
    _adeleState1.done = true;
    return _adeleTrackCancellation(_adeleState1).then((_) => true);
  }

  @override
  Future<void> close() => _adeleCloseFuture ??= _adeleClose();
  Future<void> _adeleClose() async {
    _adeleClosed = true;
    final _adeleIds0 = _adeleStreams.keys.toList(growable: false);
    await Future.wait<bool>(_adeleIds0.map(_adeleCancel));
    await Future.wait<void>(_adeleOperations.toList(growable: false));
    await Future.wait<void>(_adeleCancellations.toList(growable: false));
  }
}

String _decodeContractEnvelope(
  Map<Object?, Object?> _adeleRequest0,
  String _adeleKind1,
) {
  _contractFields(_adeleRequest0, const {
    'kind',
    'requestId',
    'method',
    'payload',
  }, 'request envelope');
  if (_adeleRequest0['requestId'] is! int ||
      _adeleRequest0['kind'] != _adeleKind1 ||
      _adeleRequest0['method'] is! String)
    throw const AdeleProtocolException('Malformed request envelope.');
  return _adeleRequest0['method'] as String;
}

final class _ContractUnknownMethod implements Exception {
  const _ContractUnknownMethod();
}

final class _ContractStreamState {
  _ContractStreamState.opening(this.requestId);
  final int requestId;
  final AdeleCompleter<void> openingSettled = AdeleCompleter<void>();
  String? method;
  AdeleStreamIterator<Object?>? iterator;
  int credit = 0;
  bool pumping = false;
  bool done = false;
}

Map<String, Object?> _contractFailure(
  Object? _adeleRequestId0,
  String? _adeleDeclaredFailureType1,
  String _adeleCode2,
  String _adeleMessage3,
  Map<String, Object?> _adeleDetails4,
) => {
  'kind': 'response',
  if (_adeleRequestId0 is int) 'requestId': _adeleRequestId0,
  'ok': false,
  'error': {
    if (_adeleDeclaredFailureType1 != null)
      'declaredFailureType': _adeleDeclaredFailureType1,
    'code': _adeleCode2,
    'message': _adeleMessage3,
    'details': _adeleDetails4,
  },
};
Map<String, Object?> _contractStreamFailure(
  Object? _adeleRequestId0,
  String? _adeleDeclaredFailureType1,
  String _adeleCode2,
  String _adeleMessage3,
  Map<String, Object?> _adeleDetails4,
) => {
  'kind': 'streamFailure',
  if (_adeleRequestId0 is int) 'requestId': _adeleRequestId0,
  'error': {
    if (_adeleDeclaredFailureType1 != null)
      'declaredFailureType': _adeleDeclaredFailureType1,
    'code': _adeleCode2,
    'message': _adeleMessage3,
    'details': _adeleDetails4,
  },
};
const String environmentFailureTypeId = 'environment.failure';
const String authorizedEnvironmentIdentityTypeId =
    'environment.authorizedIdentity';
Map<String, Object?> _encodeAuthorizedEnvironmentIdentity(
  AuthorizedEnvironmentIdentity _adeleValue187,
) => <String, Object?>{
  'environmentId': _adeleValue187.environmentId,
  'sessionId': _adeleValue187.sessionId,
};
AuthorizedEnvironmentIdentity _decodeAuthorizedEnvironmentIdentity(
  Object? _adeleValue192,
) {
  final _adeleMap193 = _contractMap(
    _adeleValue192,
    'AuthorizedEnvironmentIdentity',
  );
  _contractFields(_adeleMap193, const {
    'environmentId',
    'sessionId',
  }, 'AuthorizedEnvironmentIdentity');
  final _adeleField194 = _contractString(
    _adeleMap193['environmentId'],
    'environmentId',
  );
  final _adeleField195 = _contractString(
    _adeleMap193['sessionId'],
    'sessionId',
  );
  return _contractConstruct(
    'AuthorizedEnvironmentIdentity',
    () => AuthorizedEnvironmentIdentity(
      environmentId: _adeleField194,
      sessionId: _adeleField195,
    ),
  );
}

const String environmentTransportContextTypeId = 'environment.context';
Map<String, Object?> _encodeEnvironmentTransportContext(
  EnvironmentTransportContext _adeleValue200,
) => <String, Object?>{
  'environmentId': _adeleValue200.environmentId,
  'environmentRole': _adeleValue200.environmentRole,
  'projectId': _adeleValue200.projectId,
  'projectSourceLocation': _contractUriString(
    _adeleValue200.projectSourceLocation,
    'Uri',
  ),
  'providerId': _adeleValue200.providerId,
  'providerState': _contractJsonMap(_adeleValue200.providerState, 'map'),
  'providerStateInitialized': _adeleValue200.providerStateInitialized,
  'taskId': _adeleValue200.taskId,
  'taskTitle': _adeleValue200.taskTitle,
};
EnvironmentTransportContext _decodeEnvironmentTransportContext(
  Object? _adeleValue219,
) {
  final _adeleMap220 = _contractMap(
    _adeleValue219,
    'EnvironmentTransportContext',
  );
  _contractFields(_adeleMap220, const {
    'environmentId',
    'environmentRole',
    'projectId',
    'projectSourceLocation',
    'providerId',
    'providerState',
    'providerStateInitialized',
    'taskId',
    'taskTitle',
  }, 'EnvironmentTransportContext');
  final _adeleField221 = _contractString(
    _adeleMap220['environmentId'],
    'environmentId',
  );
  final _adeleField222 = _contractString(
    _adeleMap220['environmentRole'],
    'environmentRole',
  );
  final _adeleField223 = _contractString(
    _adeleMap220['projectId'],
    'projectId',
  );
  final _adeleField224 = _contractUri(
    _adeleMap220['projectSourceLocation'],
    'projectSourceLocation',
  );
  final _adeleField225 = _contractString(
    _adeleMap220['providerId'],
    'providerId',
  );
  final _adeleField226 = _contractJsonMap(
    _adeleMap220['providerState'],
    'providerState',
  );
  final _adeleField227 = _contractBool(
    _adeleMap220['providerStateInitialized'],
    'providerStateInitialized',
  );
  final _adeleField228 = _contractString(_adeleMap220['taskId'], 'taskId');
  final _adeleField229 = _contractString(
    _adeleMap220['taskTitle'],
    'taskTitle',
  );
  return _contractConstruct(
    'EnvironmentTransportContext',
    () => EnvironmentTransportContext(
      environmentId: _adeleField221,
      environmentRole: _adeleField222,
      projectId: _adeleField223,
      projectSourceLocation: _adeleField224,
      providerId: _adeleField225,
      providerState: _adeleField226,
      providerStateInitialized: _adeleField227,
      taskId: _adeleField228,
      taskTitle: _adeleField229,
    ),
  );
}

const String environmentDirectoryEntryTypeId = 'environment.directoryEntry';
Map<String, Object?> _encodeEnvironmentDirectoryEntry(
  EnvironmentDirectoryEntry _adeleValue248,
) => <String, Object?>{
  'kind': _adeleValue248.kind.name,
  'name': _adeleValue248.name,
  'relativePath': _adeleValue248.relativePath,
};
EnvironmentDirectoryEntry _decodeEnvironmentDirectoryEntry(
  Object? _adeleValue255,
) {
  final _adeleMap256 = _contractMap(
    _adeleValue255,
    'EnvironmentDirectoryEntry',
  );
  _contractFields(_adeleMap256, const {
    'kind',
    'name',
    'relativePath',
  }, 'EnvironmentDirectoryEntry');
  final _adeleField257 = _decodeEnvironmentDirectoryEntryKind(
    _adeleMap256['kind'],
  );
  final _adeleField258 = _contractString(_adeleMap256['name'], 'name');
  final _adeleField259 = _contractString(
    _adeleMap256['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryEntry',
    () => EnvironmentDirectoryEntry(
      kind: _adeleField257,
      name: _adeleField258,
      relativePath: _adeleField259,
    ),
  );
}

const String environmentDirectoryListingTypeId = 'environment.directoryListing';
Map<String, Object?> _encodeEnvironmentDirectoryListing(
  EnvironmentDirectoryListing _adeleValue266,
) => <String, Object?>{
  'entries': _adeleValue266.entries
      .map(
        (_adeleElement267) =>
            _encodeEnvironmentDirectoryEntry(_adeleElement267),
      )
      .toList(growable: false),
  'relativePath': _adeleValue266.relativePath,
};
EnvironmentDirectoryListing _decodeEnvironmentDirectoryListing(
  Object? _adeleValue273,
) {
  final _adeleMap274 = _contractMap(
    _adeleValue273,
    'EnvironmentDirectoryListing',
  );
  _contractFields(_adeleMap274, const {
    'entries',
    'relativePath',
  }, 'EnvironmentDirectoryListing');
  final _adeleField275 = List<EnvironmentDirectoryEntry>.unmodifiable(
    _contractList(_adeleMap274['entries'], 'entries').map(
      (_adeleElement277) => _decodeEnvironmentDirectoryEntry(_adeleElement277),
    ),
  );
  final _adeleField276 = _contractString(
    _adeleMap274['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryListing',
    () => EnvironmentDirectoryListing(
      entries: _adeleField275,
      relativePath: _adeleField276,
    ),
  );
}

const String environmentForegroundProcessRequestTypeId =
    'environment.foregroundProcessRequest';
Map<String, Object?> _encodeEnvironmentForegroundProcessRequest(
  EnvironmentForegroundProcessRequest _adeleValue283,
) => <String, Object?>{
  'arguments': _adeleValue283.arguments
      .map((_adeleElement284) => _adeleElement284)
      .toList(growable: false),
  'program': _adeleValue283.program,
  'relativeWorkingDirectory': _adeleValue283.relativeWorkingDirectory,
  'timeoutSeconds': _adeleValue283.timeoutSeconds,
};
EnvironmentForegroundProcessRequest _decodeEnvironmentForegroundProcessRequest(
  Object? _adeleValue294,
) {
  final _adeleMap295 = _contractMap(
    _adeleValue294,
    'EnvironmentForegroundProcessRequest',
  );
  _contractFields(_adeleMap295, const {
    'arguments',
    'program',
    'relativeWorkingDirectory',
    'timeoutSeconds',
  }, 'EnvironmentForegroundProcessRequest');
  final _adeleField296 = List<String>.unmodifiable(
    _contractList(_adeleMap295['arguments'], 'arguments').map(
      (_adeleElement300) =>
          _contractString(_adeleElement300, 'arguments element'),
    ),
  );
  final _adeleField297 = _contractString(_adeleMap295['program'], 'program');
  final _adeleField298 = _contractString(
    _adeleMap295['relativeWorkingDirectory'],
    'relativeWorkingDirectory',
  );
  final _adeleField299 = _contractInt(
    _adeleMap295['timeoutSeconds'],
    'timeoutSeconds',
  );
  return _contractConstruct(
    'EnvironmentForegroundProcessRequest',
    () => EnvironmentForegroundProcessRequest(
      arguments: _adeleField296,
      program: _adeleField297,
      relativeWorkingDirectory: _adeleField298,
      timeoutSeconds: _adeleField299,
    ),
  );
}

const String environmentProcessCompletedTypeId = 'environment.processCompleted';
Map<String, Object?> _encodeEnvironmentProcessCompleted(
  EnvironmentProcessCompleted _adeleValue310,
) => <String, Object?>{
  'exitCode': switch (_adeleValue310.exitCode) {
    final _adeleNonNullValue312? => _adeleNonNullValue312,
    null => null,
  },
  'stderrTruncated': _adeleValue310.stderrTruncated,
  'stdoutTruncated': _adeleValue310.stdoutTruncated,
  'termination': _adeleValue310.termination.name,
};
EnvironmentProcessCompleted _decodeEnvironmentProcessCompleted(
  Object? _adeleValue321,
) {
  final _adeleMap322 = _contractMap(
    _adeleValue321,
    'EnvironmentProcessCompleted',
  );
  _contractFields(_adeleMap322, const {
    'exitCode',
    'stderrTruncated',
    'stdoutTruncated',
    'termination',
  }, 'EnvironmentProcessCompleted');
  final _adeleField323 = switch (_adeleMap322['exitCode']) {
    final _adeleNonNullValue328? => _contractInt(
      _adeleNonNullValue328,
      'exitCode',
    ),
    null => null,
  };
  final _adeleField324 = _contractBool(
    _adeleMap322['stderrTruncated'],
    'stderrTruncated',
  );
  final _adeleField325 = _contractBool(
    _adeleMap322['stdoutTruncated'],
    'stdoutTruncated',
  );
  final _adeleField326 = _decodeEnvironmentProcessTermination(
    _adeleMap322['termination'],
  );
  return _contractConstruct(
    'EnvironmentProcessCompleted',
    () => EnvironmentProcessCompleted(
      exitCode: _adeleField323,
      stderrTruncated: _adeleField324,
      stdoutTruncated: _adeleField325,
      termination: _adeleField326,
    ),
  );
}

const String environmentProcessEventTypeId = 'environment.processEvent';
Map<String, Object?> _encodeEnvironmentProcessEvent(
  EnvironmentProcessEvent _adeleValue337,
) => <String, Object?>{
  'completed': switch (_adeleValue337.completed) {
    final _adeleNonNullValue339? => _encodeEnvironmentProcessCompleted(
      _adeleNonNullValue339,
    ),
    null => null,
  },
  'kind': _adeleValue337.kind.name,
  'output': switch (_adeleValue337.output) {
    final _adeleNonNullValue345? => _encodeEnvironmentProcessOutput(
      _adeleNonNullValue345,
    ),
    null => null,
  },
};
EnvironmentProcessEvent _decodeEnvironmentProcessEvent(Object? _adeleValue348) {
  final _adeleMap349 = _contractMap(_adeleValue348, 'EnvironmentProcessEvent');
  _contractFields(_adeleMap349, const {
    'completed',
    'kind',
    'output',
  }, 'EnvironmentProcessEvent');
  final _adeleField350 = switch (_adeleMap349['completed']) {
    final _adeleNonNullValue354? => _decodeEnvironmentProcessCompleted(
      _adeleNonNullValue354,
    ),
    null => null,
  };
  final _adeleField351 = _decodeEnvironmentProcessEventKind(
    _adeleMap349['kind'],
  );
  final _adeleField352 = switch (_adeleMap349['output']) {
    final _adeleNonNullValue360? => _decodeEnvironmentProcessOutput(
      _adeleNonNullValue360,
    ),
    null => null,
  };
  return _contractConstruct(
    'EnvironmentProcessEvent',
    () => EnvironmentProcessEvent(
      completed: _adeleField350,
      kind: _adeleField351,
      output: _adeleField352,
    ),
  );
}

const String environmentProcessOutputTypeId = 'environment.processOutput';
Map<String, Object?> _encodeEnvironmentProcessOutput(
  EnvironmentProcessOutput _adeleValue363,
) => <String, Object?>{
  'stream': _adeleValue363.stream.name,
  'text': _adeleValue363.text,
};
EnvironmentProcessOutput _decodeEnvironmentProcessOutput(
  Object? _adeleValue368,
) {
  final _adeleMap369 = _contractMap(_adeleValue368, 'EnvironmentProcessOutput');
  _contractFields(_adeleMap369, const {
    'stream',
    'text',
  }, 'EnvironmentProcessOutput');
  final _adeleField370 = _decodeEnvironmentProcessOutputStream(
    _adeleMap369['stream'],
  );
  final _adeleField371 = _contractString(_adeleMap369['text'], 'text');
  return _contractConstruct(
    'EnvironmentProcessOutput',
    () =>
        EnvironmentProcessOutput(stream: _adeleField370, text: _adeleField371),
  );
}

const String environmentProviderResultTypeId = 'environment.providerResult';
Map<String, Object?> _encodeEnvironmentProviderResult(
  EnvironmentProviderResult _adeleValue376,
) => <String, Object?>{
  'providerState': _contractJsonMap(_adeleValue376.providerState, 'map'),
};
EnvironmentProviderResult _decodeEnvironmentProviderResult(
  Object? _adeleValue379,
) {
  final _adeleMap380 = _contractMap(
    _adeleValue379,
    'EnvironmentProviderResult',
  );
  _contractFields(_adeleMap380, const {
    'providerState',
  }, 'EnvironmentProviderResult');
  final _adeleField381 = _contractJsonMap(
    _adeleMap380['providerState'],
    'providerState',
  );
  return _contractConstruct(
    'EnvironmentProviderResult',
    () => EnvironmentProviderResult(providerState: _adeleField381),
  );
}

const String environmentTextFileTypeId = 'environment.textFile';
Map<String, Object?> _encodeEnvironmentTextFile(
  EnvironmentTextFile _adeleValue384,
) => <String, Object?>{
  'relativePath': _adeleValue384.relativePath,
  'revision': _adeleValue384.revision,
  'sizeBytes': _adeleValue384.sizeBytes,
  'text': _adeleValue384.text,
};
EnvironmentTextFile _decodeEnvironmentTextFile(Object? _adeleValue393) {
  final _adeleMap394 = _contractMap(_adeleValue393, 'EnvironmentTextFile');
  _contractFields(_adeleMap394, const {
    'relativePath',
    'revision',
    'sizeBytes',
    'text',
  }, 'EnvironmentTextFile');
  final _adeleField395 = _contractString(
    _adeleMap394['relativePath'],
    'relativePath',
  );
  final _adeleField396 = _contractString(_adeleMap394['revision'], 'revision');
  final _adeleField397 = _contractInt(_adeleMap394['sizeBytes'], 'sizeBytes');
  final _adeleField398 = _contractString(_adeleMap394['text'], 'text');
  return _contractConstruct(
    'EnvironmentTextFile',
    () => EnvironmentTextFile(
      relativePath: _adeleField395,
      revision: _adeleField396,
      sizeBytes: _adeleField397,
      text: _adeleField398,
    ),
  );
}

const String environmentTextFileCreationTypeId = 'environment.textFileCreation';
Map<String, Object?> _encodeEnvironmentTextFileCreation(
  EnvironmentTextFileCreation _adeleValue407,
) => <String, Object?>{'revision': _adeleValue407.revision};
EnvironmentTextFileCreation _decodeEnvironmentTextFileCreation(
  Object? _adeleValue410,
) {
  final _adeleMap411 = _contractMap(
    _adeleValue410,
    'EnvironmentTextFileCreation',
  );
  _contractFields(_adeleMap411, const {
    'revision',
  }, 'EnvironmentTextFileCreation');
  final _adeleField412 = _contractString(_adeleMap411['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileCreation',
    () => EnvironmentTextFileCreation(revision: _adeleField412),
  );
}

const String environmentTextFileReplacementTypeId =
    'environment.textFileReplacement';
Map<String, Object?> _encodeEnvironmentTextFileReplacement(
  EnvironmentTextFileReplacement _adeleValue415,
) => <String, Object?>{'revision': _adeleValue415.revision};
EnvironmentTextFileReplacement _decodeEnvironmentTextFileReplacement(
  Object? _adeleValue418,
) {
  final _adeleMap419 = _contractMap(
    _adeleValue418,
    'EnvironmentTextFileReplacement',
  );
  _contractFields(_adeleMap419, const {
    'revision',
  }, 'EnvironmentTextFileReplacement');
  final _adeleField420 = _contractString(_adeleMap419['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileReplacement',
    () => EnvironmentTextFileReplacement(revision: _adeleField420),
  );
}

EnvironmentDirectoryEntryKind _decodeEnvironmentDirectoryEntryKind(
  Object? _adeleValue423,
) {
  if (_adeleValue423 is! String)
    throw AdeleProtocolException('Expected EnvironmentDirectoryEntryKind.');
  return switch (_adeleValue423) {
    'file' => EnvironmentDirectoryEntryKind.file,
    'directory' => EnvironmentDirectoryEntryKind.directory,
    'other' => EnvironmentDirectoryEntryKind.other,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentDirectoryEntryKind: ' + _adeleValue423 + '.',
    ),
  };
}

EnvironmentProcessEventKind _decodeEnvironmentProcessEventKind(
  Object? _adeleValue424,
) {
  if (_adeleValue424 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessEventKind.');
  return switch (_adeleValue424) {
    'output' => EnvironmentProcessEventKind.output,
    'completed' => EnvironmentProcessEventKind.completed,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessEventKind: ' + _adeleValue424 + '.',
    ),
  };
}

EnvironmentProcessOutputStream _decodeEnvironmentProcessOutputStream(
  Object? _adeleValue425,
) {
  if (_adeleValue425 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessOutputStream.');
  return switch (_adeleValue425) {
    'stdout' => EnvironmentProcessOutputStream.stdout,
    'stderr' => EnvironmentProcessOutputStream.stderr,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessOutputStream: ' + _adeleValue425 + '.',
    ),
  };
}

EnvironmentProcessTermination _decodeEnvironmentProcessTermination(
  Object? _adeleValue426,
) {
  if (_adeleValue426 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessTermination.');
  return switch (_adeleValue426) {
    'exited' => EnvironmentProcessTermination.exited,
    'timedOut' => EnvironmentProcessTermination.timedOut,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessTermination: ' + _adeleValue426 + '.',
    ),
  };
}

Map<Object?, Object?> _contractMap(Object? _adeleValue0, String _adeleLabel1) {
  if (_adeleValue0 is! Map<Object?, Object?>)
    throw AdeleProtocolException('Expected map for $_adeleLabel1.');
  for (final _adeleKey2 in _adeleValue0.keys) {
    if (_adeleKey2 is! String)
      throw AdeleProtocolException('Expected string keys for $_adeleLabel1.');
  }
  return _adeleValue0;
}

void _contractFields(
  Map<Object?, Object?> _adeleValue0,
  Set<String> _adeleExpected1,
  String _adeleLabel2,
) {
  for (final _adeleKey3 in _adeleValue0.keys) {
    if (_adeleKey3 is! String || !_adeleExpected1.contains(_adeleKey3))
      throw AdeleProtocolException(
        'Unknown field in $_adeleLabel2: $_adeleKey3.',
      );
  }
  for (final _adeleKey4 in _adeleExpected1) {
    if (!_adeleValue0.containsKey(_adeleKey4))
      throw AdeleProtocolException(
        'Missing field in $_adeleLabel2: $_adeleKey4.',
      );
  }
}

List<Object?> _contractList(Object? _adeleValue0, String _adeleLabel1) {
  if (_adeleValue0 is! List)
    throw AdeleProtocolException('Expected list for $_adeleLabel1.');
  return List<Object?>.of(_adeleValue0);
}

const int _contractJsonMaxDepth = 64;
Map<String, Object?> _contractJsonMap(
  Object? _adeleValue0,
  String _adeleLabel1,
) {
  final _adeleMap2 = _contractMap(_adeleValue0, _adeleLabel1);
  final _adeleActive3 = Set<Object>.identity();
  Object? _adeleValidate4(Object? _adeleItem5, int _adeleDepth6) {
    if (_adeleItem5 == null ||
        _adeleItem5 is String ||
        _adeleItem5 is bool ||
        _adeleItem5 is int)
      return _adeleItem5;
    if (_adeleItem5 is double) {
      _contractFiniteDouble(_adeleItem5, _adeleLabel1);
      return _adeleItem5;
    }
    if (_adeleDepth6 >= _contractJsonMaxDepth)
      throw AdeleProtocolException(
        'JSON value for $_adeleLabel1 exceeds maximum depth $_contractJsonMaxDepth.',
      );
    if (_adeleItem5 is List) {
      if (!_adeleActive3.add(_adeleItem5))
        throw AdeleProtocolException('Cyclic JSON value for $_adeleLabel1.');
      try {
        return _adeleItem5
            .map(
              (_adeleElement7) =>
                  _adeleValidate4(_adeleElement7, _adeleDepth6 + 1),
            )
            .toList(growable: false);
      } finally {
        _adeleActive3.remove(_adeleItem5);
      }
    }
    if (_adeleItem5 is Map) {
      if (!_adeleActive3.add(_adeleItem5))
        throw AdeleProtocolException('Cyclic JSON value for $_adeleLabel1.');
      try {
        final _adeleResult8 = <String, Object?>{};
        for (final _adeleEntry9 in _adeleItem5.entries) {
          if (_adeleEntry9.key is! String)
            throw AdeleProtocolException(
              'Expected string keys for $_adeleLabel1.',
            );
          _adeleResult8[_adeleEntry9.key as String] = _adeleValidate4(
            _adeleEntry9.value,
            _adeleDepth6 + 1,
          );
        }
        return _adeleResult8;
      } finally {
        _adeleActive3.remove(_adeleItem5);
      }
    }
    throw AdeleProtocolException(
      'Expected recursively JSON-compatible values for $_adeleLabel1.',
    );
  }

  return _adeleValidate4(_adeleMap2, 0) as Map<String, Object?>;
}

void _contractVoid(Object? _adeleValue0, String _adeleLabel1) {
  if (_adeleValue0 != null)
    throw AdeleProtocolException('Expected null for $_adeleLabel1.');
}

String _contractString(Object? _adeleValue0, String _adeleLabel1) {
  if (_adeleValue0 is! String)
    throw AdeleProtocolException('Expected String for $_adeleLabel1.');
  return _adeleValue0;
}

bool _contractBool(Object? _adeleValue0, String _adeleLabel1) {
  if (_adeleValue0 is! bool)
    throw AdeleProtocolException('Expected bool for $_adeleLabel1.');
  return _adeleValue0;
}

int _contractInt(Object? _adeleValue0, String _adeleLabel1) {
  if (_adeleValue0 is! int)
    throw AdeleProtocolException('Expected int for $_adeleLabel1.');
  return _adeleValue0;
}

double _contractDouble(Object? _adeleValue0, String _adeleLabel1) {
  if (_adeleValue0 is! double)
    throw AdeleProtocolException('Expected double for $_adeleLabel1.');
  return _contractFiniteDouble(_adeleValue0, _adeleLabel1);
}

double _contractFiniteDouble(double _adeleValue0, String _adeleLabel1) {
  if (!_adeleValue0.isFinite)
    throw AdeleProtocolException('Expected finite double for $_adeleLabel1.');
  return _adeleValue0;
}

Uri _contractUri(Object? _adeleValue0, String _adeleLabel1) {
  final _adeleText2 = _contractString(_adeleValue0, _adeleLabel1);
  final Uri _adeleUri3;
  try {
    _adeleUri3 = Uri.parse(_adeleText2);
  } on FormatException {
    throw AdeleProtocolException('Malformed Uri for $_adeleLabel1.');
  }
  if (!_adeleUri3.hasScheme)
    throw AdeleProtocolException('Malformed Uri for $_adeleLabel1.');
  return _adeleUri3;
}

String _contractUriString(Uri _adeleValue0, String _adeleLabel1) =>
    _contractUri(_adeleValue0.toString(), _adeleLabel1).toString();
T _contractConstruct<T>(String _adeleLabel0, T Function() _adeleConstruct1) {
  try {
    return _adeleConstruct1();
  } on Object {
    throw AdeleProtocolException('Invalid value for $_adeleLabel0.');
  }
}
