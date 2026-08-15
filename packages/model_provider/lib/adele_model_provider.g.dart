// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, use_null_aware_elements

part of 'adele_model_provider.dart';

const String modelProviderServiceId = 'modelProvider';
const String modelProviderServiceInvokeId = 'modelProvider.invoke';

final class ModelProviderServiceClient implements ModelProviderService {
  const ModelProviderServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Stream<ModelProviderEvent> invoke(ModelProviderRequest request) =>
      AdeleLazyStream<ModelProviderEvent>((
        _adeleOnData0,
        _adeleOnError1,
        _adeleOnDone2,
        _adeleCancelOnError3,
      ) {
        final _adeleStreamChannel4 = this._adeleChannel;
        if (_adeleStreamChannel4 is! AdeleStreamChannel)
          throw StateError(
            'This generated method requires an AdeleStreamChannel.',
          );
        final _adeleRaw1 = _adeleStreamChannel4.stream(
          modelProviderServiceInvokeId,
          <String, Object?>{'request': _encodeModelProviderRequest(request)},
        );
        return adeleDecodedStream<ModelProviderEvent>(
          _adeleRaw1,
          (Object? _adeleItem5) => _decodeModelProviderEvent(_adeleItem5),
          (Object _adeleError0) {
            if (_adeleError0 is AdeleRemoteFailure) {
              switch (_adeleError0.declaredFailureType) {
                case modelProviderContractFailureTypeId:
                  final _adeleDetails8 = _contractJsonMap(
                    _adeleError0.details,
                    'failure details',
                  );
                  throw _contractConstruct(
                    'ModelProviderContractFailure',
                    () => ModelProviderContractFailure(
                      code: _adeleError0.code,
                      message: _adeleError0.message,
                      details: _adeleDetails8,
                    ),
                  );
                default:
                  break;
              }
            }
            return _adeleError0;
          },
        ).listen(
          _adeleOnData0,
          onError: _adeleOnError1,
          onDone: _adeleOnDone2,
          cancelOnError: _adeleCancelOnError3,
        );
      });
}

abstract interface class ModelProviderServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class ModelProviderServiceDispatcher
    implements ModelProviderServiceRequestDispatcher {
  ModelProviderServiceDispatcher(this._adeleService);
  final ModelProviderService _adeleService;
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
        const {modelProviderServiceInvokeId}.contains(_adeleMethod2)
            ? 'wrong_method_kind'
            : 'unknown_method',
        const {modelProviderServiceInvokeId}.contains(_adeleMethod2)
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
    } on ModelProviderContractFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          modelProviderContractFailureTypeId,
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
        if (!const {modelProviderServiceInvokeId}.contains(_adeleMethod3)) {
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
          modelProviderServiceInvokeId => (() {
            _contractFields(_adelePayload4, const {
              'request',
            }, 'invoke payload');
            return <Object?>[
              _decodeModelProviderRequest(_adelePayload4['request']),
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
          modelProviderServiceInvokeId =>
            this._adeleService
                .invoke(_adeleArguments5[0] as ModelProviderRequest)
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
      } on ModelProviderContractFailure catch (_adeleError9) {
        try {
          _adeleFinish(
            _adeleState0,
            _adeleSend1,
            _contractStreamFailure(
              _adeleRequestId2,
              modelProviderContractFailureTypeId,
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
        } on ModelProviderContractFailure catch (_adeleError3) {
          try {
            _adeleFinish(
              _adeleState0,
              _adeleSend1,
              _contractStreamFailure(
                _adeleState0.requestId,
                modelProviderContractFailureTypeId,
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
            modelProviderServiceInvokeId => _encodeModelProviderEvent(
              (_adeleIterator2.current as ModelProviderEvent),
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
const String modelProviderContractFailureTypeId =
    'modelProvider.contractFailure';
const String modelProviderContentTypeId = 'modelProvider.content';
Map<String, Object?> _encodeModelProviderContent(
  ModelProviderContent _adeleValue10,
) => <String, Object?>{
  'kind': _adeleValue10.kind.name,
  'text': _adeleValue10.text,
};
ModelProviderContent _decodeModelProviderContent(Object? _adeleValue15) {
  final _adeleMap16 = _contractMap(_adeleValue15, 'ModelProviderContent');
  _contractFields(_adeleMap16, const {'kind', 'text'}, 'ModelProviderContent');
  final _adeleField17 = _decodeModelProviderContentKind(_adeleMap16['kind']);
  final _adeleField18 = _contractString(_adeleMap16['text'], 'text');
  return _contractConstruct(
    'ModelProviderContent',
    () => ModelProviderContent(kind: _adeleField17, text: _adeleField18),
  );
}

const String modelProviderEventTypeId = 'modelProvider.event';
Map<String, Object?> _encodeModelProviderEvent(
  ModelProviderEvent _adeleValue23,
) => <String, Object?>{
  'kind': _adeleValue23.kind.name,
  'observation': switch (_adeleValue23.observation) {
    final _adeleNonNullValue27? => _encodeModelProviderObservation(
      _adeleNonNullValue27,
    ),
    null => null,
  },
  'output': switch (_adeleValue23.output) {
    final _adeleNonNullValue31? => _encodeModelProviderOutput(
      _adeleNonNullValue31,
    ),
    null => null,
  },
  'terminal': switch (_adeleValue23.terminal) {
    final _adeleNonNullValue35? => _encodeModelProviderTerminal(
      _adeleNonNullValue35,
    ),
    null => null,
  },
};
ModelProviderEvent _decodeModelProviderEvent(Object? _adeleValue38) {
  final _adeleMap39 = _contractMap(_adeleValue38, 'ModelProviderEvent');
  _contractFields(_adeleMap39, const {
    'kind',
    'observation',
    'output',
    'terminal',
  }, 'ModelProviderEvent');
  final _adeleField40 = _decodeModelProviderEventKind(_adeleMap39['kind']);
  final _adeleField41 = switch (_adeleMap39['observation']) {
    final _adeleNonNullValue47? => _decodeModelProviderObservation(
      _adeleNonNullValue47,
    ),
    null => null,
  };
  final _adeleField42 = switch (_adeleMap39['output']) {
    final _adeleNonNullValue51? => _decodeModelProviderOutput(
      _adeleNonNullValue51,
    ),
    null => null,
  };
  final _adeleField43 = switch (_adeleMap39['terminal']) {
    final _adeleNonNullValue55? => _decodeModelProviderTerminal(
      _adeleNonNullValue55,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderEvent',
    () => ModelProviderEvent(
      kind: _adeleField40,
      observation: _adeleField41,
      output: _adeleField42,
      terminal: _adeleField43,
    ),
  );
}

const String modelProviderFailureTypeId = 'modelProvider.failure';
Map<String, Object?> _encodeModelProviderFailure(
  ModelProviderFailure _adeleValue58,
) => <String, Object?>{
  'kind': _adeleValue58.kind.name,
  'providerCode': switch (_adeleValue58.providerCode) {
    final _adeleNonNullValue62? => _adeleNonNullValue62,
    null => null,
  },
  'providerDetails': _contractJsonMap(_adeleValue58.providerDetails, 'map'),
  'providerMessage': switch (_adeleValue58.providerMessage) {
    final _adeleNonNullValue68? => _adeleNonNullValue68,
    null => null,
  },
};
ModelProviderFailure _decodeModelProviderFailure(Object? _adeleValue71) {
  final _adeleMap72 = _contractMap(_adeleValue71, 'ModelProviderFailure');
  _contractFields(_adeleMap72, const {
    'kind',
    'providerCode',
    'providerDetails',
    'providerMessage',
  }, 'ModelProviderFailure');
  final _adeleField73 = _decodeModelProviderFailureKind(_adeleMap72['kind']);
  final _adeleField74 = switch (_adeleMap72['providerCode']) {
    final _adeleNonNullValue80? => _contractString(
      _adeleNonNullValue80,
      'providerCode',
    ),
    null => null,
  };
  final _adeleField75 = _contractJsonMap(
    _adeleMap72['providerDetails'],
    'providerDetails',
  );
  final _adeleField76 = switch (_adeleMap72['providerMessage']) {
    final _adeleNonNullValue86? => _contractString(
      _adeleNonNullValue86,
      'providerMessage',
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderFailure',
    () => ModelProviderFailure(
      kind: _adeleField73,
      providerCode: _adeleField74,
      providerDetails: _adeleField75,
      providerMessage: _adeleField76,
    ),
  );
}

const String modelProviderInputTypeId = 'modelProvider.input';
Map<String, Object?> _encodeModelProviderInput(
  ModelProviderInput _adeleValue89,
) => <String, Object?>{
  'kind': _adeleValue89.kind.name,
  'message': switch (_adeleValue89.message) {
    final _adeleNonNullValue93? => _encodeModelProviderMessage(
      _adeleNonNullValue93,
    ),
    null => null,
  },
  'nativeMetadata': switch (_adeleValue89.nativeMetadata) {
    final _adeleNonNullValue97? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue97,
    ),
    null => null,
  },
  'toolOutcome': switch (_adeleValue89.toolOutcome) {
    final _adeleNonNullValue101? => _encodeModelProviderToolOutcome(
      _adeleNonNullValue101,
    ),
    null => null,
  },
  'toolProposal': switch (_adeleValue89.toolProposal) {
    final _adeleNonNullValue105? => _encodeModelProviderToolProposal(
      _adeleNonNullValue105,
    ),
    null => null,
  },
};
ModelProviderInput _decodeModelProviderInput(Object? _adeleValue108) {
  final _adeleMap109 = _contractMap(_adeleValue108, 'ModelProviderInput');
  _contractFields(_adeleMap109, const {
    'kind',
    'message',
    'nativeMetadata',
    'toolOutcome',
    'toolProposal',
  }, 'ModelProviderInput');
  final _adeleField110 = _decodeModelProviderInputKind(_adeleMap109['kind']);
  final _adeleField111 = switch (_adeleMap109['message']) {
    final _adeleNonNullValue118? => _decodeModelProviderMessage(
      _adeleNonNullValue118,
    ),
    null => null,
  };
  final _adeleField112 = switch (_adeleMap109['nativeMetadata']) {
    final _adeleNonNullValue122? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue122,
    ),
    null => null,
  };
  final _adeleField113 = switch (_adeleMap109['toolOutcome']) {
    final _adeleNonNullValue126? => _decodeModelProviderToolOutcome(
      _adeleNonNullValue126,
    ),
    null => null,
  };
  final _adeleField114 = switch (_adeleMap109['toolProposal']) {
    final _adeleNonNullValue130? => _decodeModelProviderToolProposal(
      _adeleNonNullValue130,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderInput',
    () => ModelProviderInput(
      kind: _adeleField110,
      message: _adeleField111,
      nativeMetadata: _adeleField112,
      toolOutcome: _adeleField113,
      toolProposal: _adeleField114,
    ),
  );
}

const String modelProviderMessageTypeId = 'modelProvider.message';
Map<String, Object?> _encodeModelProviderMessage(
  ModelProviderMessage _adeleValue133,
) => <String, Object?>{
  'content': _adeleValue133.content
      .map((_adeleElement134) => _encodeModelProviderContent(_adeleElement134))
      .toList(growable: false),
  'role': _adeleValue133.role.name,
};
ModelProviderMessage _decodeModelProviderMessage(Object? _adeleValue140) {
  final _adeleMap141 = _contractMap(_adeleValue140, 'ModelProviderMessage');
  _contractFields(_adeleMap141, const {
    'content',
    'role',
  }, 'ModelProviderMessage');
  final _adeleField142 = List<ModelProviderContent>.unmodifiable(
    _contractList(
      _adeleMap141['content'],
      'content',
    ).map((_adeleElement144) => _decodeModelProviderContent(_adeleElement144)),
  );
  final _adeleField143 = _decodeModelProviderMessageRole(_adeleMap141['role']);
  return _contractConstruct(
    'ModelProviderMessage',
    () => ModelProviderMessage(content: _adeleField142, role: _adeleField143),
  );
}

const String modelProviderNativeEnvelopeTypeId = 'modelProvider.nativeEnvelope';
Map<String, Object?> _encodeModelProviderNativeEnvelope(
  ModelProviderNativeEnvelope _adeleValue150,
) => <String, Object?>{
  'compatibility': _contractJsonMap(_adeleValue150.compatibility, 'map'),
  'data': _contractJsonMap(_adeleValue150.data, 'map'),
  'kind': _adeleValue150.kind,
};
ModelProviderNativeEnvelope _decodeModelProviderNativeEnvelope(
  Object? _adeleValue157,
) {
  final _adeleMap158 = _contractMap(
    _adeleValue157,
    'ModelProviderNativeEnvelope',
  );
  _contractFields(_adeleMap158, const {
    'compatibility',
    'data',
    'kind',
  }, 'ModelProviderNativeEnvelope');
  final _adeleField159 = _contractJsonMap(
    _adeleMap158['compatibility'],
    'compatibility',
  );
  final _adeleField160 = _contractJsonMap(_adeleMap158['data'], 'data');
  final _adeleField161 = _contractString(_adeleMap158['kind'], 'kind');
  return _contractConstruct(
    'ModelProviderNativeEnvelope',
    () => ModelProviderNativeEnvelope(
      compatibility: _adeleField159,
      data: _adeleField160,
      kind: _adeleField161,
    ),
  );
}

const String modelProviderObservationTypeId = 'modelProvider.observation';
Map<String, Object?> _encodeModelProviderObservation(
  ModelProviderObservation _adeleValue168,
) => <String, Object?>{
  'itemId': switch (_adeleValue168.itemId) {
    final _adeleNonNullValue170? => _adeleNonNullValue170,
    null => null,
  },
  'kind': _adeleValue168.kind.name,
  'textDelta': _adeleValue168.textDelta,
};
ModelProviderObservation _decodeModelProviderObservation(
  Object? _adeleValue177,
) {
  final _adeleMap178 = _contractMap(_adeleValue177, 'ModelProviderObservation');
  _contractFields(_adeleMap178, const {
    'itemId',
    'kind',
    'textDelta',
  }, 'ModelProviderObservation');
  final _adeleField179 = switch (_adeleMap178['itemId']) {
    final _adeleNonNullValue183? => _contractString(
      _adeleNonNullValue183,
      'itemId',
    ),
    null => null,
  };
  final _adeleField180 = _decodeModelProviderObservationKind(
    _adeleMap178['kind'],
  );
  final _adeleField181 = _contractString(
    _adeleMap178['textDelta'],
    'textDelta',
  );
  return _contractConstruct(
    'ModelProviderObservation',
    () => ModelProviderObservation(
      itemId: _adeleField179,
      kind: _adeleField180,
      textDelta: _adeleField181,
    ),
  );
}

const String modelProviderOutputTypeId = 'modelProvider.output';
Map<String, Object?> _encodeModelProviderOutput(
  ModelProviderOutput _adeleValue190,
) => <String, Object?>{
  'itemId': switch (_adeleValue190.itemId) {
    final _adeleNonNullValue192? => _adeleNonNullValue192,
    null => null,
  },
  'kind': _adeleValue190.kind.name,
  'nativeMetadata': switch (_adeleValue190.nativeMetadata) {
    final _adeleNonNullValue198? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue198,
    ),
    null => null,
  },
  'text': switch (_adeleValue190.text) {
    final _adeleNonNullValue202? => _adeleNonNullValue202,
    null => null,
  },
  'toolProposal': switch (_adeleValue190.toolProposal) {
    final _adeleNonNullValue206? => _encodeModelProviderToolProposal(
      _adeleNonNullValue206,
    ),
    null => null,
  },
};
ModelProviderOutput _decodeModelProviderOutput(Object? _adeleValue209) {
  final _adeleMap210 = _contractMap(_adeleValue209, 'ModelProviderOutput');
  _contractFields(_adeleMap210, const {
    'itemId',
    'kind',
    'nativeMetadata',
    'text',
    'toolProposal',
  }, 'ModelProviderOutput');
  final _adeleField211 = switch (_adeleMap210['itemId']) {
    final _adeleNonNullValue217? => _contractString(
      _adeleNonNullValue217,
      'itemId',
    ),
    null => null,
  };
  final _adeleField212 = _decodeModelProviderOutputKind(_adeleMap210['kind']);
  final _adeleField213 = switch (_adeleMap210['nativeMetadata']) {
    final _adeleNonNullValue223? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue223,
    ),
    null => null,
  };
  final _adeleField214 = switch (_adeleMap210['text']) {
    final _adeleNonNullValue227? => _contractString(
      _adeleNonNullValue227,
      'text',
    ),
    null => null,
  };
  final _adeleField215 = switch (_adeleMap210['toolProposal']) {
    final _adeleNonNullValue231? => _decodeModelProviderToolProposal(
      _adeleNonNullValue231,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderOutput',
    () => ModelProviderOutput(
      itemId: _adeleField211,
      kind: _adeleField212,
      nativeMetadata: _adeleField213,
      text: _adeleField214,
      toolProposal: _adeleField215,
    ),
  );
}

const String modelProviderRequestTypeId = 'modelProvider.request';
Map<String, Object?> _encodeModelProviderRequest(
  ModelProviderRequest _adeleValue234,
) => <String, Object?>{
  'input': _adeleValue234.input
      .map((_adeleElement235) => _encodeModelProviderInput(_adeleElement235))
      .toList(growable: false),
  'instructions': _adeleValue234.instructions,
  'maxOutputTokens': switch (_adeleValue234.maxOutputTokens) {
    final _adeleNonNullValue242? => _adeleNonNullValue242,
    null => null,
  },
  'model': _adeleValue234.model,
  'nativeState': switch (_adeleValue234.nativeState) {
    final _adeleNonNullValue248? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue248,
    ),
    null => null,
  },
  'providerOptions': _contractJsonMap(_adeleValue234.providerOptions, 'map'),
  'toolChoice': _adeleValue234.toolChoice.name,
  'tools': _adeleValue234.tools
      .map((_adeleElement255) => _encodeModelProviderTool(_adeleElement255))
      .toList(growable: false),
};
ModelProviderRequest _decodeModelProviderRequest(Object? _adeleValue259) {
  final _adeleMap260 = _contractMap(_adeleValue259, 'ModelProviderRequest');
  _contractFields(_adeleMap260, const {
    'input',
    'instructions',
    'maxOutputTokens',
    'model',
    'nativeState',
    'providerOptions',
    'toolChoice',
    'tools',
  }, 'ModelProviderRequest');
  final _adeleField261 = List<ModelProviderInput>.unmodifiable(
    _contractList(
      _adeleMap260['input'],
      'input',
    ).map((_adeleElement269) => _decodeModelProviderInput(_adeleElement269)),
  );
  final _adeleField262 = _contractString(
    _adeleMap260['instructions'],
    'instructions',
  );
  final _adeleField263 = switch (_adeleMap260['maxOutputTokens']) {
    final _adeleNonNullValue276? => _contractInt(
      _adeleNonNullValue276,
      'maxOutputTokens',
    ),
    null => null,
  };
  final _adeleField264 = _contractString(_adeleMap260['model'], 'model');
  final _adeleField265 = switch (_adeleMap260['nativeState']) {
    final _adeleNonNullValue282? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue282,
    ),
    null => null,
  };
  final _adeleField266 = _contractJsonMap(
    _adeleMap260['providerOptions'],
    'providerOptions',
  );
  final _adeleField267 = _decodeModelProviderToolChoice(
    _adeleMap260['toolChoice'],
  );
  final _adeleField268 = List<ModelProviderTool>.unmodifiable(
    _contractList(
      _adeleMap260['tools'],
      'tools',
    ).map((_adeleElement289) => _decodeModelProviderTool(_adeleElement289)),
  );
  return _contractConstruct(
    'ModelProviderRequest',
    () => ModelProviderRequest(
      input: _adeleField261,
      instructions: _adeleField262,
      maxOutputTokens: _adeleField263,
      model: _adeleField264,
      nativeState: _adeleField265,
      providerOptions: _adeleField266,
      toolChoice: _adeleField267,
      tools: _adeleField268,
    ),
  );
}

const String modelProviderTerminalTypeId = 'modelProvider.terminal';
Map<String, Object?> _encodeModelProviderTerminal(
  ModelProviderTerminal _adeleValue293,
) => <String, Object?>{
  'effectiveModel': switch (_adeleValue293.effectiveModel) {
    final _adeleNonNullValue295? => _adeleNonNullValue295,
    null => null,
  },
  'failure': switch (_adeleValue293.failure) {
    final _adeleNonNullValue299? => _encodeModelProviderFailure(
      _adeleNonNullValue299,
    ),
    null => null,
  },
  'incompleteReason': switch (_adeleValue293.incompleteReason) {
    final _adeleNonNullValue303? => _adeleNonNullValue303.name,
    null => null,
  },
  'nativeState': switch (_adeleValue293.nativeState) {
    final _adeleNonNullValue307? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue307,
    ),
    null => null,
  },
  'providerStopReason': switch (_adeleValue293.providerStopReason) {
    final _adeleNonNullValue311? => _adeleNonNullValue311,
    null => null,
  },
  'requestId': switch (_adeleValue293.requestId) {
    final _adeleNonNullValue315? => _adeleNonNullValue315,
    null => null,
  },
  'responseId': switch (_adeleValue293.responseId) {
    final _adeleNonNullValue319? => _adeleNonNullValue319,
    null => null,
  },
  'settlement': _adeleValue293.settlement.name,
  'usage': switch (_adeleValue293.usage) {
    final _adeleNonNullValue325? => _encodeModelProviderUsage(
      _adeleNonNullValue325,
    ),
    null => null,
  },
};
ModelProviderTerminal _decodeModelProviderTerminal(Object? _adeleValue328) {
  final _adeleMap329 = _contractMap(_adeleValue328, 'ModelProviderTerminal');
  _contractFields(_adeleMap329, const {
    'effectiveModel',
    'failure',
    'incompleteReason',
    'nativeState',
    'providerStopReason',
    'requestId',
    'responseId',
    'settlement',
    'usage',
  }, 'ModelProviderTerminal');
  final _adeleField330 = switch (_adeleMap329['effectiveModel']) {
    final _adeleNonNullValue340? => _contractString(
      _adeleNonNullValue340,
      'effectiveModel',
    ),
    null => null,
  };
  final _adeleField331 = switch (_adeleMap329['failure']) {
    final _adeleNonNullValue344? => _decodeModelProviderFailure(
      _adeleNonNullValue344,
    ),
    null => null,
  };
  final _adeleField332 = switch (_adeleMap329['incompleteReason']) {
    final _adeleNonNullValue348? => _decodeModelProviderIncompleteReason(
      _adeleNonNullValue348,
    ),
    null => null,
  };
  final _adeleField333 = switch (_adeleMap329['nativeState']) {
    final _adeleNonNullValue352? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue352,
    ),
    null => null,
  };
  final _adeleField334 = switch (_adeleMap329['providerStopReason']) {
    final _adeleNonNullValue356? => _contractString(
      _adeleNonNullValue356,
      'providerStopReason',
    ),
    null => null,
  };
  final _adeleField335 = switch (_adeleMap329['requestId']) {
    final _adeleNonNullValue360? => _contractString(
      _adeleNonNullValue360,
      'requestId',
    ),
    null => null,
  };
  final _adeleField336 = switch (_adeleMap329['responseId']) {
    final _adeleNonNullValue364? => _contractString(
      _adeleNonNullValue364,
      'responseId',
    ),
    null => null,
  };
  final _adeleField337 = _decodeModelProviderSettlement(
    _adeleMap329['settlement'],
  );
  final _adeleField338 = switch (_adeleMap329['usage']) {
    final _adeleNonNullValue370? => _decodeModelProviderUsage(
      _adeleNonNullValue370,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderTerminal',
    () => ModelProviderTerminal(
      effectiveModel: _adeleField330,
      failure: _adeleField331,
      incompleteReason: _adeleField332,
      nativeState: _adeleField333,
      providerStopReason: _adeleField334,
      requestId: _adeleField335,
      responseId: _adeleField336,
      settlement: _adeleField337,
      usage: _adeleField338,
    ),
  );
}

const String modelProviderToolTypeId = 'modelProvider.tool';
Map<String, Object?> _encodeModelProviderTool(
  ModelProviderTool _adeleValue373,
) => <String, Object?>{
  'argumentsSchema': _contractJsonMap(_adeleValue373.argumentsSchema, 'map'),
  'description': _adeleValue373.description,
  'name': _adeleValue373.name,
};
ModelProviderTool _decodeModelProviderTool(Object? _adeleValue380) {
  final _adeleMap381 = _contractMap(_adeleValue380, 'ModelProviderTool');
  _contractFields(_adeleMap381, const {
    'argumentsSchema',
    'description',
    'name',
  }, 'ModelProviderTool');
  final _adeleField382 = _contractJsonMap(
    _adeleMap381['argumentsSchema'],
    'argumentsSchema',
  );
  final _adeleField383 = _contractString(
    _adeleMap381['description'],
    'description',
  );
  final _adeleField384 = _contractString(_adeleMap381['name'], 'name');
  return _contractConstruct(
    'ModelProviderTool',
    () => ModelProviderTool(
      argumentsSchema: _adeleField382,
      description: _adeleField383,
      name: _adeleField384,
    ),
  );
}

const String modelProviderToolOutcomeTypeId = 'modelProvider.toolOutcome';
Map<String, Object?> _encodeModelProviderToolOutcome(
  ModelProviderToolOutcome _adeleValue391,
) => <String, Object?>{
  'callId': _adeleValue391.callId,
  'content': _adeleValue391.content,
  'status': _adeleValue391.status.name,
};
ModelProviderToolOutcome _decodeModelProviderToolOutcome(
  Object? _adeleValue398,
) {
  final _adeleMap399 = _contractMap(_adeleValue398, 'ModelProviderToolOutcome');
  _contractFields(_adeleMap399, const {
    'callId',
    'content',
    'status',
  }, 'ModelProviderToolOutcome');
  final _adeleField400 = _contractString(_adeleMap399['callId'], 'callId');
  final _adeleField401 = _contractString(_adeleMap399['content'], 'content');
  final _adeleField402 = _decodeModelProviderToolOutcomeStatus(
    _adeleMap399['status'],
  );
  return _contractConstruct(
    'ModelProviderToolOutcome',
    () => ModelProviderToolOutcome(
      callId: _adeleField400,
      content: _adeleField401,
      status: _adeleField402,
    ),
  );
}

const String modelProviderToolProposalTypeId = 'modelProvider.toolProposal';
Map<String, Object?> _encodeModelProviderToolProposal(
  ModelProviderToolProposal _adeleValue409,
) => <String, Object?>{
  'arguments': _contractJsonMap(_adeleValue409.arguments, 'map'),
  'callId': _adeleValue409.callId,
  'itemId': switch (_adeleValue409.itemId) {
    final _adeleNonNullValue415? => _adeleNonNullValue415,
    null => null,
  },
  'name': _adeleValue409.name,
  'nativeMetadata': switch (_adeleValue409.nativeMetadata) {
    final _adeleNonNullValue421? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue421,
    ),
    null => null,
  },
};
ModelProviderToolProposal _decodeModelProviderToolProposal(
  Object? _adeleValue424,
) {
  final _adeleMap425 = _contractMap(
    _adeleValue424,
    'ModelProviderToolProposal',
  );
  _contractFields(_adeleMap425, const {
    'arguments',
    'callId',
    'itemId',
    'name',
    'nativeMetadata',
  }, 'ModelProviderToolProposal');
  final _adeleField426 = _contractJsonMap(
    _adeleMap425['arguments'],
    'arguments',
  );
  final _adeleField427 = _contractString(_adeleMap425['callId'], 'callId');
  final _adeleField428 = switch (_adeleMap425['itemId']) {
    final _adeleNonNullValue436? => _contractString(
      _adeleNonNullValue436,
      'itemId',
    ),
    null => null,
  };
  final _adeleField429 = _contractString(_adeleMap425['name'], 'name');
  final _adeleField430 = switch (_adeleMap425['nativeMetadata']) {
    final _adeleNonNullValue442? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue442,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderToolProposal',
    () => ModelProviderToolProposal(
      arguments: _adeleField426,
      callId: _adeleField427,
      itemId: _adeleField428,
      name: _adeleField429,
      nativeMetadata: _adeleField430,
    ),
  );
}

const String modelProviderUsageTypeId = 'modelProvider.usage';
Map<String, Object?> _encodeModelProviderUsage(
  ModelProviderUsage _adeleValue445,
) => <String, Object?>{
  'cacheReadTokens': switch (_adeleValue445.cacheReadTokens) {
    final _adeleNonNullValue447? => _adeleNonNullValue447,
    null => null,
  },
  'cacheWriteTokens': switch (_adeleValue445.cacheWriteTokens) {
    final _adeleNonNullValue451? => _adeleNonNullValue451,
    null => null,
  },
  'inputTokens': switch (_adeleValue445.inputTokens) {
    final _adeleNonNullValue455? => _adeleNonNullValue455,
    null => null,
  },
  'outputTokens': switch (_adeleValue445.outputTokens) {
    final _adeleNonNullValue459? => _adeleNonNullValue459,
    null => null,
  },
  'providerDetails': _contractJsonMap(_adeleValue445.providerDetails, 'map'),
};
ModelProviderUsage _decodeModelProviderUsage(Object? _adeleValue464) {
  final _adeleMap465 = _contractMap(_adeleValue464, 'ModelProviderUsage');
  _contractFields(_adeleMap465, const {
    'cacheReadTokens',
    'cacheWriteTokens',
    'inputTokens',
    'outputTokens',
    'providerDetails',
  }, 'ModelProviderUsage');
  final _adeleField466 = switch (_adeleMap465['cacheReadTokens']) {
    final _adeleNonNullValue472? => _contractInt(
      _adeleNonNullValue472,
      'cacheReadTokens',
    ),
    null => null,
  };
  final _adeleField467 = switch (_adeleMap465['cacheWriteTokens']) {
    final _adeleNonNullValue476? => _contractInt(
      _adeleNonNullValue476,
      'cacheWriteTokens',
    ),
    null => null,
  };
  final _adeleField468 = switch (_adeleMap465['inputTokens']) {
    final _adeleNonNullValue480? => _contractInt(
      _adeleNonNullValue480,
      'inputTokens',
    ),
    null => null,
  };
  final _adeleField469 = switch (_adeleMap465['outputTokens']) {
    final _adeleNonNullValue484? => _contractInt(
      _adeleNonNullValue484,
      'outputTokens',
    ),
    null => null,
  };
  final _adeleField470 = _contractJsonMap(
    _adeleMap465['providerDetails'],
    'providerDetails',
  );
  return _contractConstruct(
    'ModelProviderUsage',
    () => ModelProviderUsage(
      cacheReadTokens: _adeleField466,
      cacheWriteTokens: _adeleField467,
      inputTokens: _adeleField468,
      outputTokens: _adeleField469,
      providerDetails: _adeleField470,
    ),
  );
}

ModelProviderContentKind _decodeModelProviderContentKind(
  Object? _adeleValue489,
) {
  if (_adeleValue489 is! String)
    throw AdeleProtocolException('Expected ModelProviderContentKind.');
  return switch (_adeleValue489) {
    'text' => ModelProviderContentKind.text,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderContentKind: ' + _adeleValue489 + '.',
    ),
  };
}

ModelProviderEventKind _decodeModelProviderEventKind(Object? _adeleValue490) {
  if (_adeleValue490 is! String)
    throw AdeleProtocolException('Expected ModelProviderEventKind.');
  return switch (_adeleValue490) {
    'observation' => ModelProviderEventKind.observation,
    'output' => ModelProviderEventKind.output,
    'terminal' => ModelProviderEventKind.terminal,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderEventKind: ' + _adeleValue490 + '.',
    ),
  };
}

ModelProviderFailureKind _decodeModelProviderFailureKind(
  Object? _adeleValue491,
) {
  if (_adeleValue491 is! String)
    throw AdeleProtocolException('Expected ModelProviderFailureKind.');
  return switch (_adeleValue491) {
    'invalidRequest' => ModelProviderFailureKind.invalidRequest,
    'unsupportedRequest' => ModelProviderFailureKind.unsupportedRequest,
    'authentication' => ModelProviderFailureKind.authentication,
    'permission' => ModelProviderFailureKind.permission,
    'rateLimited' => ModelProviderFailureKind.rateLimited,
    'unavailable' => ModelProviderFailureKind.unavailable,
    'capacity' => ModelProviderFailureKind.capacity,
    'transport' => ModelProviderFailureKind.transport,
    'malformedResponse' => ModelProviderFailureKind.malformedResponse,
    'providerFailure' => ModelProviderFailureKind.providerFailure,
    'unknown' => ModelProviderFailureKind.unknown,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderFailureKind: ' + _adeleValue491 + '.',
    ),
  };
}

ModelProviderIncompleteReason _decodeModelProviderIncompleteReason(
  Object? _adeleValue492,
) {
  if (_adeleValue492 is! String)
    throw AdeleProtocolException('Expected ModelProviderIncompleteReason.');
  return switch (_adeleValue492) {
    'outputLimit' => ModelProviderIncompleteReason.outputLimit,
    'contextLimit' => ModelProviderIncompleteReason.contextLimit,
    'other' => ModelProviderIncompleteReason.other,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderIncompleteReason: ' + _adeleValue492 + '.',
    ),
  };
}

ModelProviderInputKind _decodeModelProviderInputKind(Object? _adeleValue493) {
  if (_adeleValue493 is! String)
    throw AdeleProtocolException('Expected ModelProviderInputKind.');
  return switch (_adeleValue493) {
    'message' => ModelProviderInputKind.message,
    'toolProposal' => ModelProviderInputKind.toolProposal,
    'toolOutcome' => ModelProviderInputKind.toolOutcome,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderInputKind: ' + _adeleValue493 + '.',
    ),
  };
}

ModelProviderMessageRole _decodeModelProviderMessageRole(
  Object? _adeleValue494,
) {
  if (_adeleValue494 is! String)
    throw AdeleProtocolException('Expected ModelProviderMessageRole.');
  return switch (_adeleValue494) {
    'user' => ModelProviderMessageRole.user,
    'assistant' => ModelProviderMessageRole.assistant,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderMessageRole: ' + _adeleValue494 + '.',
    ),
  };
}

ModelProviderObservationKind _decodeModelProviderObservationKind(
  Object? _adeleValue495,
) {
  if (_adeleValue495 is! String)
    throw AdeleProtocolException('Expected ModelProviderObservationKind.');
  return switch (_adeleValue495) {
    'textDelta' => ModelProviderObservationKind.textDelta,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderObservationKind: ' + _adeleValue495 + '.',
    ),
  };
}

ModelProviderOutputKind _decodeModelProviderOutputKind(Object? _adeleValue496) {
  if (_adeleValue496 is! String)
    throw AdeleProtocolException('Expected ModelProviderOutputKind.');
  return switch (_adeleValue496) {
    'text' => ModelProviderOutputKind.text,
    'toolProposal' => ModelProviderOutputKind.toolProposal,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderOutputKind: ' + _adeleValue496 + '.',
    ),
  };
}

ModelProviderSettlement _decodeModelProviderSettlement(Object? _adeleValue497) {
  if (_adeleValue497 is! String)
    throw AdeleProtocolException('Expected ModelProviderSettlement.');
  return switch (_adeleValue497) {
    'completed' => ModelProviderSettlement.completed,
    'incomplete' => ModelProviderSettlement.incomplete,
    'refused' => ModelProviderSettlement.refused,
    'failed' => ModelProviderSettlement.failed,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderSettlement: ' + _adeleValue497 + '.',
    ),
  };
}

ModelProviderToolChoice _decodeModelProviderToolChoice(Object? _adeleValue498) {
  if (_adeleValue498 is! String)
    throw AdeleProtocolException('Expected ModelProviderToolChoice.');
  return switch (_adeleValue498) {
    'auto' => ModelProviderToolChoice.auto,
    'none' => ModelProviderToolChoice.none,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderToolChoice: ' + _adeleValue498 + '.',
    ),
  };
}

ModelProviderToolOutcomeStatus _decodeModelProviderToolOutcomeStatus(
  Object? _adeleValue499,
) {
  if (_adeleValue499 is! String)
    throw AdeleProtocolException('Expected ModelProviderToolOutcomeStatus.');
  return switch (_adeleValue499) {
    'success' => ModelProviderToolOutcomeStatus.success,
    'rejected' => ModelProviderToolOutcomeStatus.rejected,
    'failed' => ModelProviderToolOutcomeStatus.failed,
    'cancelled' => ModelProviderToolOutcomeStatus.cancelled,
    'indeterminate' => ModelProviderToolOutcomeStatus.indeterminate,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderToolOutcomeStatus: ' + _adeleValue499 + '.',
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
