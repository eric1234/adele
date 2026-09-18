// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'remote_model_tool.dart';

const String remoteModelToolServiceId = 'modelTool';
const String remoteModelToolServiceDescribeId = 'modelTool.describe';
const String remoteModelToolServiceExecuteId = 'modelTool.execute';
const String remoteModelToolServiceMaterializeId = 'modelTool.materialize';
const String remoteModelToolServiceValidateAndNormalizeId =
    'modelTool.validateAndNormalize';

final class RemoteModelToolServiceClient implements RemoteModelToolService {
  const RemoteModelToolServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<RemoteEffectDescription> describe(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? environmentId,
  ) async {
    try {
      return _decodeRemoteEffectDescription(
        await this._adeleChannel
            .request(remoteModelToolServiceDescribeId, <String, Object?>{
              'routeId': routeId,
              'arguments': _encodeRemoteCanonicalToolArguments(arguments),
              'sessionId': sessionId,
              'runId': runId,
              'environmentId': switch (environmentId) {
                final _adeleNonNullValue10? => _adeleNonNullValue10,
                null => null,
              },
            }),
      );
    } on AdeleRemoteFailure catch (_adeleError0) {
      switch (_adeleError0.declaredFailureType) {
        case remoteToolArgumentValidationFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError0.details,
            'failure details',
          );
          throw _contractConstruct(
            'RemoteToolArgumentValidationFailure',
            () => RemoteToolArgumentValidationFailure(
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
  Stream<RemoteToolExecutionEvent> execute(
    String routeId,
    RemoteCanonicalToolArguments arguments,
    String sessionId,
    String runId,
    String? environmentId,
    String? hostInvocationContext,
  ) => AdeleLazyStream<RemoteToolExecutionEvent>((
    _adeleOnData0,
    _adeleOnError1,
    _adeleOnDone2,
    _adeleCancelOnError3,
  ) {
    final _adeleStreamChannel4 = this._adeleChannel;
    if (_adeleStreamChannel4 is! AdeleStreamChannel)
      throw StateError('This generated method requires an AdeleStreamChannel.');
    final _adeleRaw16 = _adeleStreamChannel4
        .stream(remoteModelToolServiceExecuteId, <String, Object?>{
          'routeId': routeId,
          'arguments': _encodeRemoteCanonicalToolArguments(arguments),
          'sessionId': sessionId,
          'runId': runId,
          'environmentId': switch (environmentId) {
            final _adeleNonNullValue26? => _adeleNonNullValue26,
            null => null,
          },
          'hostInvocationContext': switch (hostInvocationContext) {
            final _adeleNonNullValue30? => _adeleNonNullValue30,
            null => null,
          },
        });
    return adeleDecodedStream<RemoteToolExecutionEvent>(
      _adeleRaw16,
      (Object? _adeleItem5) => _decodeRemoteToolExecutionEvent(_adeleItem5),
      (Object _adeleError15) {
        if (_adeleError15 is AdeleRemoteFailure) {
          switch (_adeleError15.declaredFailureType) {
            case remoteToolArgumentValidationFailureTypeId:
              final _adeleDetails8 = _contractJsonMap(
                _adeleError15.details,
                'failure details',
              );
              throw _contractConstruct(
                'RemoteToolArgumentValidationFailure',
                () => RemoteToolArgumentValidationFailure(
                  code: _adeleError15.code,
                  message: _adeleError15.message,
                  details: _adeleDetails8,
                ),
              );
            default:
              break;
          }
        }
        return _adeleError15;
      },
    ).listen(
      _adeleOnData0,
      onError: _adeleOnError1,
      onDone: _adeleOnDone2,
      cancelOnError: _adeleCancelOnError3,
    );
  });
  @override
  Future<List<RemoteToolDescriptor>> materialize(String sessionId) async {
    try {
      return List<RemoteToolDescriptor>.unmodifiable(
        _contractList(
          await this._adeleChannel.request(
            remoteModelToolServiceMaterializeId,
            <String, Object?>{'sessionId': sessionId},
          ),
          'materialize',
        ).map(
          (_adeleElement38) => _decodeRemoteToolDescriptor(_adeleElement38),
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError35) {
      switch (_adeleError35.declaredFailureType) {
        case remoteToolArgumentValidationFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError35.details,
            'failure details',
          );
          throw _contractConstruct(
            'RemoteToolArgumentValidationFailure',
            () => RemoteToolArgumentValidationFailure(
              code: _adeleError35.code,
              message: _adeleError35.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<RemoteCanonicalToolArguments> validateAndNormalize(
    String routeId,
    Map<String, Object?> proposedArguments,
  ) async {
    try {
      return _decodeRemoteCanonicalToolArguments(
        await this._adeleChannel.request(
          remoteModelToolServiceValidateAndNormalizeId,
          <String, Object?>{
            'routeId': routeId,
            'proposedArguments': _contractJsonMap(proposedArguments, 'map'),
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError42) {
      switch (_adeleError42.declaredFailureType) {
        case remoteToolArgumentValidationFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError42.details,
            'failure details',
          );
          throw _contractConstruct(
            'RemoteToolArgumentValidationFailure',
            () => RemoteToolArgumentValidationFailure(
              code: _adeleError42.code,
              message: _adeleError42.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class RemoteModelToolServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class RemoteModelToolServiceDispatcher
    implements RemoteModelToolServiceRequestDispatcher {
  RemoteModelToolServiceDispatcher(this._adeleService);
  final RemoteModelToolService _adeleService;
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
      remoteModelToolServiceDescribeId,
      remoteModelToolServiceMaterializeId,
      remoteModelToolServiceValidateAndNormalizeId,
    }.contains(_adeleMethod2))
      return _contractFailure(
        _adeleRequestId1,
        null,
        const {remoteModelToolServiceExecuteId}.contains(_adeleMethod2)
            ? 'wrong_method_kind'
            : 'unknown_method',
        const {remoteModelToolServiceExecuteId}.contains(_adeleMethod2)
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
        remoteModelToolServiceDescribeId => (() {
          _contractFields(_adelePayload4, const {
            'routeId',
            'arguments',
            'sessionId',
            'runId',
            'environmentId',
          }, 'describe payload');
          return <Object?>[
            _contractString(_adelePayload4['routeId'], 'routeId'),
            _decodeRemoteCanonicalToolArguments(_adelePayload4['arguments']),
            _contractString(_adelePayload4['sessionId'], 'sessionId'),
            _contractString(_adelePayload4['runId'], 'runId'),
            switch (_adelePayload4['environmentId']) {
              final _adeleNonNullValue58? => _contractString(
                _adeleNonNullValue58,
                'environmentId',
              ),
              null => null,
            },
          ];
        })(),
        remoteModelToolServiceMaterializeId => (() {
          _contractFields(_adelePayload4, const {
            'sessionId',
          }, 'materialize payload');
          return <Object?>[
            _contractString(_adelePayload4['sessionId'], 'sessionId'),
          ];
        })(),
        remoteModelToolServiceValidateAndNormalizeId => (() {
          _contractFields(_adelePayload4, const {
            'routeId',
            'proposedArguments',
          }, 'validateAndNormalize payload');
          return <Object?>[
            _contractString(_adelePayload4['routeId'], 'routeId'),
            _contractJsonMap(
              _adelePayload4['proposedArguments'],
              'proposedArguments',
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
        remoteModelToolServiceDescribeId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.describe(
            _adeleValues0[0] as String,
            _adeleValues0[1] as RemoteCanonicalToolArguments,
            _adeleValues0[2] as String,
            _adeleValues0[3] as String,
            _adeleValues0[4] as String?,
          );
        })(),
        remoteModelToolServiceMaterializeId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.materialize(
            _adeleValues0[0] as String,
          );
        })(),
        remoteModelToolServiceValidateAndNormalizeId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.validateAndNormalize(
            _adeleValues0[0] as String,
            _adeleValues0[1] as Map<String, Object?>,
          );
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on RemoteToolArgumentValidationFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          remoteToolArgumentValidationFailureTypeId,
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
        remoteModelToolServiceDescribeId => _encodeRemoteEffectDescription(
          (_adeleResult8 as RemoteEffectDescription),
        ),
        remoteModelToolServiceMaterializeId =>
          (_adeleResult8 as List<RemoteToolDescriptor>)
              .map(
                (_adeleElement69) =>
                    _encodeRemoteToolDescriptor(_adeleElement69),
              )
              .toList(growable: false),
        remoteModelToolServiceValidateAndNormalizeId =>
          _encodeRemoteCanonicalToolArguments(
            (_adeleResult8 as RemoteCanonicalToolArguments),
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
        if (!const {remoteModelToolServiceExecuteId}.contains(_adeleMethod3)) {
          final _adeleWrongKind6 = const {
            remoteModelToolServiceDescribeId,
            remoteModelToolServiceMaterializeId,
            remoteModelToolServiceValidateAndNormalizeId,
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
          remoteModelToolServiceExecuteId => (() {
            _contractFields(_adelePayload4, const {
              'routeId',
              'arguments',
              'sessionId',
              'runId',
              'environmentId',
              'hostInvocationContext',
            }, 'execute payload');
            return <Object?>[
              _contractString(_adelePayload4['routeId'], 'routeId'),
              _decodeRemoteCanonicalToolArguments(_adelePayload4['arguments']),
              _contractString(_adelePayload4['sessionId'], 'sessionId'),
              _contractString(_adelePayload4['runId'], 'runId'),
              switch (_adelePayload4['environmentId']) {
                final _adeleNonNullValue84? => _contractString(
                  _adeleNonNullValue84,
                  'environmentId',
                ),
                null => null,
              },
              switch (_adelePayload4['hostInvocationContext']) {
                final _adeleNonNullValue88? => _contractString(
                  _adeleNonNullValue88,
                  'hostInvocationContext',
                ),
                null => null,
              },
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
          remoteModelToolServiceExecuteId =>
            this._adeleService
                .execute(
                  _adeleArguments5[0] as String,
                  _adeleArguments5[1] as RemoteCanonicalToolArguments,
                  _adeleArguments5[2] as String,
                  _adeleArguments5[3] as String,
                  _adeleArguments5[4] as String?,
                  _adeleArguments5[5] as String?,
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
      } on RemoteToolArgumentValidationFailure catch (_adeleError9) {
        try {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              remoteToolArgumentValidationFailureTypeId,
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
        } on RemoteToolArgumentValidationFailure catch (_adeleError3) {
          try {
            _adeleFinish(
              _adeleState0,
              _adeleSend1,
              _contractStreamFailure(
                _adeleState0.requestId,
                remoteToolArgumentValidationFailureTypeId,
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
            remoteModelToolServiceExecuteId => _encodeRemoteToolExecutionEvent(
              (_adeleIterator2.current as RemoteToolExecutionEvent),
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
const String remoteToolArgumentValidationFailureTypeId =
    'modelTool.argumentValidationFailure';
const String remoteCanonicalToolArgumentsTypeId =
    'modelTool.canonicalArguments';
Map<String, Object?> _encodeRemoteCanonicalToolArguments(
  RemoteCanonicalToolArguments _adeleValue93,
) => <String, Object?>{
  'snapshot': _contractJsonMap(_adeleValue93.snapshot, 'map'),
};
RemoteCanonicalToolArguments _decodeRemoteCanonicalToolArguments(
  Object? _adeleValue96,
) {
  final _adeleMap97 = _contractMap(
    _adeleValue96,
    'RemoteCanonicalToolArguments',
  );
  _contractFields(_adeleMap97, const {
    'snapshot',
  }, 'RemoteCanonicalToolArguments');
  final _adeleField98 = _contractJsonMap(_adeleMap97['snapshot'], 'snapshot');
  return _contractConstruct(
    'RemoteCanonicalToolArguments',
    () => RemoteCanonicalToolArguments(snapshot: _adeleField98),
  );
}

const String remoteToolDescriptorTypeId = 'modelTool.descriptor';
Map<String, Object?> _encodeRemoteToolDescriptor(
  RemoteToolDescriptor _adeleValue101,
) => <String, Object?>{
  'argumentsSchema': _contractJsonMap(_adeleValue101.argumentsSchema, 'map'),
  'executionHostServices': _adeleValue101.executionHostServices
      .map((_adeleElement104) => _adeleElement104)
      .toList(growable: false),
  'modelAlias': _adeleValue101.modelAlias,
  'modelDescription': _adeleValue101.modelDescription,
  'routeId': _adeleValue101.routeId,
  'toolDescription': _adeleValue101.toolDescription,
  'toolId': _adeleValue101.toolId,
};
RemoteToolDescriptor _decodeRemoteToolDescriptor(Object? _adeleValue118) {
  final _adeleMap119 = _contractMap(_adeleValue118, 'RemoteToolDescriptor');
  _contractFields(_adeleMap119, const {
    'argumentsSchema',
    'executionHostServices',
    'modelAlias',
    'modelDescription',
    'routeId',
    'toolDescription',
    'toolId',
  }, 'RemoteToolDescriptor');
  final _adeleField120 = _contractJsonMap(
    _adeleMap119['argumentsSchema'],
    'argumentsSchema',
  );
  final _adeleField121 = List<String>.unmodifiable(
    _contractList(
      _adeleMap119['executionHostServices'],
      'executionHostServices',
    ).map(
      (_adeleElement129) =>
          _contractString(_adeleElement129, 'executionHostServices element'),
    ),
  );
  final _adeleField122 = _contractString(
    _adeleMap119['modelAlias'],
    'modelAlias',
  );
  final _adeleField123 = _contractString(
    _adeleMap119['modelDescription'],
    'modelDescription',
  );
  final _adeleField124 = _contractString(_adeleMap119['routeId'], 'routeId');
  final _adeleField125 = _contractString(
    _adeleMap119['toolDescription'],
    'toolDescription',
  );
  final _adeleField126 = _contractString(_adeleMap119['toolId'], 'toolId');
  return _contractConstruct(
    'RemoteToolDescriptor',
    () => RemoteToolDescriptor(
      argumentsSchema: _adeleField120,
      executionHostServices: _adeleField121,
      modelAlias: _adeleField122,
      modelDescription: _adeleField123,
      routeId: _adeleField124,
      toolDescription: _adeleField125,
      toolId: _adeleField126,
    ),
  );
}

const String remoteEffectDescriptionTypeId = 'modelTool.effectDescription';
Map<String, Object?> _encodeRemoteEffectDescription(
  RemoteEffectDescription _adeleValue143,
) => <String, Object?>{
  'effects': _adeleValue143.effects
      .map((_adeleElement144) => _adeleElement144.name)
      .toList(growable: false),
  'summary': _adeleValue143.summary,
  'targetUris': _adeleValue143.targetUris
      .map((_adeleElement150) => _contractUriString(_adeleElement150, 'Uri'))
      .toList(growable: false),
  'uncertainty': _adeleValue143.uncertainty.name,
};
RemoteEffectDescription _decodeRemoteEffectDescription(Object? _adeleValue156) {
  final _adeleMap157 = _contractMap(_adeleValue156, 'RemoteEffectDescription');
  _contractFields(_adeleMap157, const {
    'effects',
    'summary',
    'targetUris',
    'uncertainty',
  }, 'RemoteEffectDescription');
  final _adeleField158 = List<RemoteToolEffect>.unmodifiable(
    _contractList(
      _adeleMap157['effects'],
      'effects',
    ).map((_adeleElement162) => _decodeRemoteToolEffect(_adeleElement162)),
  );
  final _adeleField159 = _contractString(_adeleMap157['summary'], 'summary');
  final _adeleField160 = List<Uri>.unmodifiable(
    _contractList(_adeleMap157['targetUris'], 'targetUris').map(
      (_adeleElement168) =>
          _contractUri(_adeleElement168, 'targetUris element'),
    ),
  );
  final _adeleField161 = _decodeRemoteEffectUncertainty(
    _adeleMap157['uncertainty'],
  );
  return _contractConstruct(
    'RemoteEffectDescription',
    () => RemoteEffectDescription(
      effects: _adeleField158,
      summary: _adeleField159,
      targetUris: _adeleField160,
      uncertainty: _adeleField161,
    ),
  );
}

const String remoteToolExecutionEventTypeId = 'modelTool.executionEvent';
Map<String, Object?> _encodeRemoteToolExecutionEvent(
  RemoteToolExecutionEvent _adeleValue174,
) => <String, Object?>{
  'kind': _adeleValue174.kind.name,
  'outcome': switch (_adeleValue174.outcome) {
    final _adeleNonNullValue178? => _encodeRemoteToolOutcome(
      _adeleNonNullValue178,
    ),
    null => null,
  },
  'progress': switch (_adeleValue174.progress) {
    final _adeleNonNullValue182? => _encodeRemoteToolProgress(
      _adeleNonNullValue182,
    ),
    null => null,
  },
};
RemoteToolExecutionEvent _decodeRemoteToolExecutionEvent(
  Object? _adeleValue185,
) {
  final _adeleMap186 = _contractMap(_adeleValue185, 'RemoteToolExecutionEvent');
  _contractFields(_adeleMap186, const {
    'kind',
    'outcome',
    'progress',
  }, 'RemoteToolExecutionEvent');
  final _adeleField187 = _decodeRemoteToolExecutionEventKind(
    _adeleMap186['kind'],
  );
  final _adeleField188 = switch (_adeleMap186['outcome']) {
    final _adeleNonNullValue193? => _decodeRemoteToolOutcome(
      _adeleNonNullValue193,
    ),
    null => null,
  };
  final _adeleField189 = switch (_adeleMap186['progress']) {
    final _adeleNonNullValue197? => _decodeRemoteToolProgress(
      _adeleNonNullValue197,
    ),
    null => null,
  };
  return _contractConstruct(
    'RemoteToolExecutionEvent',
    () => RemoteToolExecutionEvent(
      kind: _adeleField187,
      outcome: _adeleField188,
      progress: _adeleField189,
    ),
  );
}

const String remoteToolOutcomeTypeId = 'modelTool.outcome';
Map<String, Object?> _encodeRemoteToolOutcome(
  RemoteToolOutcome _adeleValue200,
) => <String, Object?>{
  'disposition': _adeleValue200.disposition.name,
  'effectCertainty': _adeleValue200.effectCertainty.name,
  'failureKind': switch (_adeleValue200.failureKind) {
    final _adeleNonNullValue206? => _adeleNonNullValue206.name,
    null => null,
  },
  'hostData': _contractJsonMap(_adeleValue200.hostData, 'map'),
  'hostDiagnostic': switch (_adeleValue200.hostDiagnostic) {
    final _adeleNonNullValue212? => _adeleNonNullValue212,
    null => null,
  },
  'modelContent': _adeleValue200.modelContent,
};
RemoteToolOutcome _decodeRemoteToolOutcome(Object? _adeleValue217) {
  final _adeleMap218 = _contractMap(_adeleValue217, 'RemoteToolOutcome');
  _contractFields(_adeleMap218, const {
    'disposition',
    'effectCertainty',
    'failureKind',
    'hostData',
    'hostDiagnostic',
    'modelContent',
  }, 'RemoteToolOutcome');
  final _adeleField219 = _decodeRemoteToolOutcomeDisposition(
    _adeleMap218['disposition'],
  );
  final _adeleField220 = _decodeRemoteEffectCertainty(
    _adeleMap218['effectCertainty'],
  );
  final _adeleField221 = switch (_adeleMap218['failureKind']) {
    final _adeleNonNullValue230? => _decodeRemoteToolFailureKind(
      _adeleNonNullValue230,
    ),
    null => null,
  };
  final _adeleField222 = _contractJsonMap(_adeleMap218['hostData'], 'hostData');
  final _adeleField223 = switch (_adeleMap218['hostDiagnostic']) {
    final _adeleNonNullValue236? => _contractString(
      _adeleNonNullValue236,
      'hostDiagnostic',
    ),
    null => null,
  };
  final _adeleField224 = _contractString(
    _adeleMap218['modelContent'],
    'modelContent',
  );
  return _contractConstruct(
    'RemoteToolOutcome',
    () => RemoteToolOutcome(
      disposition: _adeleField219,
      effectCertainty: _adeleField220,
      failureKind: _adeleField221,
      hostData: _adeleField222,
      hostDiagnostic: _adeleField223,
      modelContent: _adeleField224,
    ),
  );
}

const String remoteToolProgressTypeId = 'modelTool.progress';
Map<String, Object?> _encodeRemoteToolProgress(
  RemoteToolProgress _adeleValue241,
) => <String, Object?>{
  'content': _adeleValue241.content,
  'kind': _adeleValue241.kind.name,
};
RemoteToolProgress _decodeRemoteToolProgress(Object? _adeleValue246) {
  final _adeleMap247 = _contractMap(_adeleValue246, 'RemoteToolProgress');
  _contractFields(_adeleMap247, const {
    'content',
    'kind',
  }, 'RemoteToolProgress');
  final _adeleField248 = _contractString(_adeleMap247['content'], 'content');
  final _adeleField249 = _decodeRemoteToolProgressKind(_adeleMap247['kind']);
  return _contractConstruct(
    'RemoteToolProgress',
    () => RemoteToolProgress(content: _adeleField248, kind: _adeleField249),
  );
}

RemoteEffectCertainty _decodeRemoteEffectCertainty(Object? _adeleValue254) {
  if (_adeleValue254 is! String)
    throw AdeleProtocolException('Expected RemoteEffectCertainty.');
  return switch (_adeleValue254) {
    'knownNotOccurred' => RemoteEffectCertainty.knownNotOccurred,
    'knownOccurred' => RemoteEffectCertainty.knownOccurred,
    'uncertain' => RemoteEffectCertainty.uncertain,
    _ => throw AdeleProtocolException(
      'Unknown RemoteEffectCertainty: ' + _adeleValue254 + '.',
    ),
  };
}

RemoteEffectUncertainty _decodeRemoteEffectUncertainty(Object? _adeleValue255) {
  if (_adeleValue255 is! String)
    throw AdeleProtocolException('Expected RemoteEffectUncertainty.');
  return switch (_adeleValue255) {
    'none' => RemoteEffectUncertainty.none,
    'uncertain' => RemoteEffectUncertainty.uncertain,
    _ => throw AdeleProtocolException(
      'Unknown RemoteEffectUncertainty: ' + _adeleValue255 + '.',
    ),
  };
}

RemoteToolEffect _decodeRemoteToolEffect(Object? _adeleValue256) {
  if (_adeleValue256 is! String)
    throw AdeleProtocolException('Expected RemoteToolEffect.');
  return switch (_adeleValue256) {
    'resourceInspection' => RemoteToolEffect.resourceInspection,
    'sourceRead' => RemoteToolEffect.sourceRead,
    'sourceMutation' => RemoteToolEffect.sourceMutation,
    'processExecution' => RemoteToolEffect.processExecution,
    _ => throw AdeleProtocolException(
      'Unknown RemoteToolEffect: ' + _adeleValue256 + '.',
    ),
  };
}

RemoteToolExecutionEventKind _decodeRemoteToolExecutionEventKind(
  Object? _adeleValue257,
) {
  if (_adeleValue257 is! String)
    throw AdeleProtocolException('Expected RemoteToolExecutionEventKind.');
  return switch (_adeleValue257) {
    'progress' => RemoteToolExecutionEventKind.progress,
    'terminal' => RemoteToolExecutionEventKind.terminal,
    _ => throw AdeleProtocolException(
      'Unknown RemoteToolExecutionEventKind: ' + _adeleValue257 + '.',
    ),
  };
}

RemoteToolFailureKind _decodeRemoteToolFailureKind(Object? _adeleValue258) {
  if (_adeleValue258 is! String)
    throw AdeleProtocolException('Expected RemoteToolFailureKind.');
  return switch (_adeleValue258) {
    'domain' => RemoteToolFailureKind.domain,
    'infrastructure' => RemoteToolFailureKind.infrastructure,
    'staleBinding' => RemoteToolFailureKind.staleBinding,
    _ => throw AdeleProtocolException(
      'Unknown RemoteToolFailureKind: ' + _adeleValue258 + '.',
    ),
  };
}

RemoteToolOutcomeDisposition _decodeRemoteToolOutcomeDisposition(
  Object? _adeleValue259,
) {
  if (_adeleValue259 is! String)
    throw AdeleProtocolException('Expected RemoteToolOutcomeDisposition.');
  return switch (_adeleValue259) {
    'success' => RemoteToolOutcomeDisposition.success,
    'userRejected' => RemoteToolOutcomeDisposition.userRejected,
    'policyDenied' => RemoteToolOutcomeDisposition.policyDenied,
    'failure' => RemoteToolOutcomeDisposition.failure,
    'cancelled' => RemoteToolOutcomeDisposition.cancelled,
    'indeterminate' => RemoteToolOutcomeDisposition.indeterminate,
    _ => throw AdeleProtocolException(
      'Unknown RemoteToolOutcomeDisposition: ' + _adeleValue259 + '.',
    ),
  };
}

RemoteToolProgressKind _decodeRemoteToolProgressKind(Object? _adeleValue260) {
  if (_adeleValue260 is! String)
    throw AdeleProtocolException('Expected RemoteToolProgressKind.');
  return switch (_adeleValue260) {
    'status' => RemoteToolProgressKind.status,
    'stdout' => RemoteToolProgressKind.stdout,
    'stderr' => RemoteToolProgressKind.stderr,
    _ => throw AdeleProtocolException(
      'Unknown RemoteToolProgressKind: ' + _adeleValue260 + '.',
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
