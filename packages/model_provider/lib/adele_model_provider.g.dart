// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

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
  'itemId': switch (_adeleValue89.itemId) {
    final _adeleNonNullValue91? => _adeleNonNullValue91,
    null => null,
  },
  'kind': _adeleValue89.kind.name,
  'message': switch (_adeleValue89.message) {
    final _adeleNonNullValue97? => _encodeModelProviderMessage(
      _adeleNonNullValue97,
    ),
    null => null,
  },
  'nativeMetadata': switch (_adeleValue89.nativeMetadata) {
    final _adeleNonNullValue101? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue101,
    ),
    null => null,
  },
  'toolOutcome': switch (_adeleValue89.toolOutcome) {
    final _adeleNonNullValue105? => _encodeModelProviderToolOutcome(
      _adeleNonNullValue105,
    ),
    null => null,
  },
  'toolProposal': switch (_adeleValue89.toolProposal) {
    final _adeleNonNullValue109? => _encodeModelProviderToolProposal(
      _adeleNonNullValue109,
    ),
    null => null,
  },
};
ModelProviderInput _decodeModelProviderInput(Object? _adeleValue112) {
  final _adeleMap113 = _contractMap(_adeleValue112, 'ModelProviderInput');
  _contractFields(_adeleMap113, const {
    'itemId',
    'kind',
    'message',
    'nativeMetadata',
    'toolOutcome',
    'toolProposal',
  }, 'ModelProviderInput');
  final _adeleField114 = switch (_adeleMap113['itemId']) {
    final _adeleNonNullValue121? => _contractString(
      _adeleNonNullValue121,
      'itemId',
    ),
    null => null,
  };
  final _adeleField115 = _decodeModelProviderInputKind(_adeleMap113['kind']);
  final _adeleField116 = switch (_adeleMap113['message']) {
    final _adeleNonNullValue127? => _decodeModelProviderMessage(
      _adeleNonNullValue127,
    ),
    null => null,
  };
  final _adeleField117 = switch (_adeleMap113['nativeMetadata']) {
    final _adeleNonNullValue131? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue131,
    ),
    null => null,
  };
  final _adeleField118 = switch (_adeleMap113['toolOutcome']) {
    final _adeleNonNullValue135? => _decodeModelProviderToolOutcome(
      _adeleNonNullValue135,
    ),
    null => null,
  };
  final _adeleField119 = switch (_adeleMap113['toolProposal']) {
    final _adeleNonNullValue139? => _decodeModelProviderToolProposal(
      _adeleNonNullValue139,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderInput',
    () => ModelProviderInput(
      itemId: _adeleField114,
      kind: _adeleField115,
      message: _adeleField116,
      nativeMetadata: _adeleField117,
      toolOutcome: _adeleField118,
      toolProposal: _adeleField119,
    ),
  );
}

const String modelProviderMessageTypeId = 'modelProvider.message';
Map<String, Object?> _encodeModelProviderMessage(
  ModelProviderMessage _adeleValue142,
) => <String, Object?>{
  'content': _adeleValue142.content
      .map((_adeleElement143) => _encodeModelProviderContent(_adeleElement143))
      .toList(growable: false),
  'role': _adeleValue142.role.name,
};
ModelProviderMessage _decodeModelProviderMessage(Object? _adeleValue149) {
  final _adeleMap150 = _contractMap(_adeleValue149, 'ModelProviderMessage');
  _contractFields(_adeleMap150, const {
    'content',
    'role',
  }, 'ModelProviderMessage');
  final _adeleField151 = List<ModelProviderContent>.unmodifiable(
    _contractList(
      _adeleMap150['content'],
      'content',
    ).map((_adeleElement153) => _decodeModelProviderContent(_adeleElement153)),
  );
  final _adeleField152 = _decodeModelProviderMessageRole(_adeleMap150['role']);
  return _contractConstruct(
    'ModelProviderMessage',
    () => ModelProviderMessage(content: _adeleField151, role: _adeleField152),
  );
}

const String modelProviderNativeEnvelopeTypeId = 'modelProvider.nativeEnvelope';
Map<String, Object?> _encodeModelProviderNativeEnvelope(
  ModelProviderNativeEnvelope _adeleValue159,
) => <String, Object?>{
  'compatibility': _contractJsonMap(_adeleValue159.compatibility, 'map'),
  'data': _contractJsonMap(_adeleValue159.data, 'map'),
  'kind': _adeleValue159.kind,
};
ModelProviderNativeEnvelope _decodeModelProviderNativeEnvelope(
  Object? _adeleValue166,
) {
  final _adeleMap167 = _contractMap(
    _adeleValue166,
    'ModelProviderNativeEnvelope',
  );
  _contractFields(_adeleMap167, const {
    'compatibility',
    'data',
    'kind',
  }, 'ModelProviderNativeEnvelope');
  final _adeleField168 = _contractJsonMap(
    _adeleMap167['compatibility'],
    'compatibility',
  );
  final _adeleField169 = _contractJsonMap(_adeleMap167['data'], 'data');
  final _adeleField170 = _contractString(_adeleMap167['kind'], 'kind');
  return _contractConstruct(
    'ModelProviderNativeEnvelope',
    () => ModelProviderNativeEnvelope(
      compatibility: _adeleField168,
      data: _adeleField169,
      kind: _adeleField170,
    ),
  );
}

const String modelProviderObservationTypeId = 'modelProvider.observation';
Map<String, Object?> _encodeModelProviderObservation(
  ModelProviderObservation _adeleValue177,
) => <String, Object?>{
  'itemId': switch (_adeleValue177.itemId) {
    final _adeleNonNullValue179? => _adeleNonNullValue179,
    null => null,
  },
  'kind': _adeleValue177.kind.name,
  'textDelta': _adeleValue177.textDelta,
};
ModelProviderObservation _decodeModelProviderObservation(
  Object? _adeleValue186,
) {
  final _adeleMap187 = _contractMap(_adeleValue186, 'ModelProviderObservation');
  _contractFields(_adeleMap187, const {
    'itemId',
    'kind',
    'textDelta',
  }, 'ModelProviderObservation');
  final _adeleField188 = switch (_adeleMap187['itemId']) {
    final _adeleNonNullValue192? => _contractString(
      _adeleNonNullValue192,
      'itemId',
    ),
    null => null,
  };
  final _adeleField189 = _decodeModelProviderObservationKind(
    _adeleMap187['kind'],
  );
  final _adeleField190 = _contractString(
    _adeleMap187['textDelta'],
    'textDelta',
  );
  return _contractConstruct(
    'ModelProviderObservation',
    () => ModelProviderObservation(
      itemId: _adeleField188,
      kind: _adeleField189,
      textDelta: _adeleField190,
    ),
  );
}

const String modelProviderOutputTypeId = 'modelProvider.output';
Map<String, Object?> _encodeModelProviderOutput(
  ModelProviderOutput _adeleValue199,
) => <String, Object?>{
  'itemId': switch (_adeleValue199.itemId) {
    final _adeleNonNullValue201? => _adeleNonNullValue201,
    null => null,
  },
  'kind': _adeleValue199.kind.name,
  'nativeMetadata': switch (_adeleValue199.nativeMetadata) {
    final _adeleNonNullValue207? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue207,
    ),
    null => null,
  },
  'text': switch (_adeleValue199.text) {
    final _adeleNonNullValue211? => _adeleNonNullValue211,
    null => null,
  },
  'toolProposal': switch (_adeleValue199.toolProposal) {
    final _adeleNonNullValue215? => _encodeModelProviderToolProposal(
      _adeleNonNullValue215,
    ),
    null => null,
  },
};
ModelProviderOutput _decodeModelProviderOutput(Object? _adeleValue218) {
  final _adeleMap219 = _contractMap(_adeleValue218, 'ModelProviderOutput');
  _contractFields(_adeleMap219, const {
    'itemId',
    'kind',
    'nativeMetadata',
    'text',
    'toolProposal',
  }, 'ModelProviderOutput');
  final _adeleField220 = switch (_adeleMap219['itemId']) {
    final _adeleNonNullValue226? => _contractString(
      _adeleNonNullValue226,
      'itemId',
    ),
    null => null,
  };
  final _adeleField221 = _decodeModelProviderOutputKind(_adeleMap219['kind']);
  final _adeleField222 = switch (_adeleMap219['nativeMetadata']) {
    final _adeleNonNullValue232? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue232,
    ),
    null => null,
  };
  final _adeleField223 = switch (_adeleMap219['text']) {
    final _adeleNonNullValue236? => _contractString(
      _adeleNonNullValue236,
      'text',
    ),
    null => null,
  };
  final _adeleField224 = switch (_adeleMap219['toolProposal']) {
    final _adeleNonNullValue240? => _decodeModelProviderToolProposal(
      _adeleNonNullValue240,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderOutput',
    () => ModelProviderOutput(
      itemId: _adeleField220,
      kind: _adeleField221,
      nativeMetadata: _adeleField222,
      text: _adeleField223,
      toolProposal: _adeleField224,
    ),
  );
}

const String modelProviderRequestTypeId = 'modelProvider.request';
Map<String, Object?> _encodeModelProviderRequest(
  ModelProviderRequest _adeleValue243,
) => <String, Object?>{
  'input': _adeleValue243.input
      .map((_adeleElement244) => _encodeModelProviderInput(_adeleElement244))
      .toList(growable: false),
  'instructions': _adeleValue243.instructions,
  'maxOutputTokens': switch (_adeleValue243.maxOutputTokens) {
    final _adeleNonNullValue251? => _adeleNonNullValue251,
    null => null,
  },
  'model': _adeleValue243.model,
  'nativeState': switch (_adeleValue243.nativeState) {
    final _adeleNonNullValue257? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue257,
    ),
    null => null,
  },
  'providerOptions': _contractJsonMap(_adeleValue243.providerOptions, 'map'),
  'toolChoice': _adeleValue243.toolChoice.name,
  'tools': _adeleValue243.tools
      .map((_adeleElement264) => _encodeModelProviderTool(_adeleElement264))
      .toList(growable: false),
};
ModelProviderRequest _decodeModelProviderRequest(Object? _adeleValue268) {
  final _adeleMap269 = _contractMap(_adeleValue268, 'ModelProviderRequest');
  _contractFields(_adeleMap269, const {
    'input',
    'instructions',
    'maxOutputTokens',
    'model',
    'nativeState',
    'providerOptions',
    'toolChoice',
    'tools',
  }, 'ModelProviderRequest');
  final _adeleField270 = List<ModelProviderInput>.unmodifiable(
    _contractList(
      _adeleMap269['input'],
      'input',
    ).map((_adeleElement278) => _decodeModelProviderInput(_adeleElement278)),
  );
  final _adeleField271 = _contractString(
    _adeleMap269['instructions'],
    'instructions',
  );
  final _adeleField272 = switch (_adeleMap269['maxOutputTokens']) {
    final _adeleNonNullValue285? => _contractInt(
      _adeleNonNullValue285,
      'maxOutputTokens',
    ),
    null => null,
  };
  final _adeleField273 = _contractString(_adeleMap269['model'], 'model');
  final _adeleField274 = switch (_adeleMap269['nativeState']) {
    final _adeleNonNullValue291? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue291,
    ),
    null => null,
  };
  final _adeleField275 = _contractJsonMap(
    _adeleMap269['providerOptions'],
    'providerOptions',
  );
  final _adeleField276 = _decodeModelProviderToolChoice(
    _adeleMap269['toolChoice'],
  );
  final _adeleField277 = List<ModelProviderTool>.unmodifiable(
    _contractList(
      _adeleMap269['tools'],
      'tools',
    ).map((_adeleElement298) => _decodeModelProviderTool(_adeleElement298)),
  );
  return _contractConstruct(
    'ModelProviderRequest',
    () => ModelProviderRequest(
      input: _adeleField270,
      instructions: _adeleField271,
      maxOutputTokens: _adeleField272,
      model: _adeleField273,
      nativeState: _adeleField274,
      providerOptions: _adeleField275,
      toolChoice: _adeleField276,
      tools: _adeleField277,
    ),
  );
}

const String modelProviderTerminalTypeId = 'modelProvider.terminal';
Map<String, Object?> _encodeModelProviderTerminal(
  ModelProviderTerminal _adeleValue302,
) => <String, Object?>{
  'effectiveModel': switch (_adeleValue302.effectiveModel) {
    final _adeleNonNullValue304? => _adeleNonNullValue304,
    null => null,
  },
  'failure': switch (_adeleValue302.failure) {
    final _adeleNonNullValue308? => _encodeModelProviderFailure(
      _adeleNonNullValue308,
    ),
    null => null,
  },
  'incompleteReason': switch (_adeleValue302.incompleteReason) {
    final _adeleNonNullValue312? => _adeleNonNullValue312.name,
    null => null,
  },
  'nativeState': switch (_adeleValue302.nativeState) {
    final _adeleNonNullValue316? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue316,
    ),
    null => null,
  },
  'providerStopReason': switch (_adeleValue302.providerStopReason) {
    final _adeleNonNullValue320? => _adeleNonNullValue320,
    null => null,
  },
  'requestId': switch (_adeleValue302.requestId) {
    final _adeleNonNullValue324? => _adeleNonNullValue324,
    null => null,
  },
  'responseId': switch (_adeleValue302.responseId) {
    final _adeleNonNullValue328? => _adeleNonNullValue328,
    null => null,
  },
  'settlement': _adeleValue302.settlement.name,
  'usage': switch (_adeleValue302.usage) {
    final _adeleNonNullValue334? => _encodeModelProviderUsage(
      _adeleNonNullValue334,
    ),
    null => null,
  },
};
ModelProviderTerminal _decodeModelProviderTerminal(Object? _adeleValue337) {
  final _adeleMap338 = _contractMap(_adeleValue337, 'ModelProviderTerminal');
  _contractFields(_adeleMap338, const {
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
  final _adeleField339 = switch (_adeleMap338['effectiveModel']) {
    final _adeleNonNullValue349? => _contractString(
      _adeleNonNullValue349,
      'effectiveModel',
    ),
    null => null,
  };
  final _adeleField340 = switch (_adeleMap338['failure']) {
    final _adeleNonNullValue353? => _decodeModelProviderFailure(
      _adeleNonNullValue353,
    ),
    null => null,
  };
  final _adeleField341 = switch (_adeleMap338['incompleteReason']) {
    final _adeleNonNullValue357? => _decodeModelProviderIncompleteReason(
      _adeleNonNullValue357,
    ),
    null => null,
  };
  final _adeleField342 = switch (_adeleMap338['nativeState']) {
    final _adeleNonNullValue361? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue361,
    ),
    null => null,
  };
  final _adeleField343 = switch (_adeleMap338['providerStopReason']) {
    final _adeleNonNullValue365? => _contractString(
      _adeleNonNullValue365,
      'providerStopReason',
    ),
    null => null,
  };
  final _adeleField344 = switch (_adeleMap338['requestId']) {
    final _adeleNonNullValue369? => _contractString(
      _adeleNonNullValue369,
      'requestId',
    ),
    null => null,
  };
  final _adeleField345 = switch (_adeleMap338['responseId']) {
    final _adeleNonNullValue373? => _contractString(
      _adeleNonNullValue373,
      'responseId',
    ),
    null => null,
  };
  final _adeleField346 = _decodeModelProviderSettlement(
    _adeleMap338['settlement'],
  );
  final _adeleField347 = switch (_adeleMap338['usage']) {
    final _adeleNonNullValue379? => _decodeModelProviderUsage(
      _adeleNonNullValue379,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderTerminal',
    () => ModelProviderTerminal(
      effectiveModel: _adeleField339,
      failure: _adeleField340,
      incompleteReason: _adeleField341,
      nativeState: _adeleField342,
      providerStopReason: _adeleField343,
      requestId: _adeleField344,
      responseId: _adeleField345,
      settlement: _adeleField346,
      usage: _adeleField347,
    ),
  );
}

const String modelProviderToolTypeId = 'modelProvider.tool';
Map<String, Object?> _encodeModelProviderTool(
  ModelProviderTool _adeleValue382,
) => <String, Object?>{
  'argumentsSchema': _contractJsonMap(_adeleValue382.argumentsSchema, 'map'),
  'description': _adeleValue382.description,
  'name': _adeleValue382.name,
};
ModelProviderTool _decodeModelProviderTool(Object? _adeleValue389) {
  final _adeleMap390 = _contractMap(_adeleValue389, 'ModelProviderTool');
  _contractFields(_adeleMap390, const {
    'argumentsSchema',
    'description',
    'name',
  }, 'ModelProviderTool');
  final _adeleField391 = _contractJsonMap(
    _adeleMap390['argumentsSchema'],
    'argumentsSchema',
  );
  final _adeleField392 = _contractString(
    _adeleMap390['description'],
    'description',
  );
  final _adeleField393 = _contractString(_adeleMap390['name'], 'name');
  return _contractConstruct(
    'ModelProviderTool',
    () => ModelProviderTool(
      argumentsSchema: _adeleField391,
      description: _adeleField392,
      name: _adeleField393,
    ),
  );
}

const String modelProviderToolOutcomeTypeId = 'modelProvider.toolOutcome';
Map<String, Object?> _encodeModelProviderToolOutcome(
  ModelProviderToolOutcome _adeleValue400,
) => <String, Object?>{
  'callId': _adeleValue400.callId,
  'content': _adeleValue400.content,
  'status': _adeleValue400.status.name,
};
ModelProviderToolOutcome _decodeModelProviderToolOutcome(
  Object? _adeleValue407,
) {
  final _adeleMap408 = _contractMap(_adeleValue407, 'ModelProviderToolOutcome');
  _contractFields(_adeleMap408, const {
    'callId',
    'content',
    'status',
  }, 'ModelProviderToolOutcome');
  final _adeleField409 = _contractString(_adeleMap408['callId'], 'callId');
  final _adeleField410 = _contractString(_adeleMap408['content'], 'content');
  final _adeleField411 = _decodeModelProviderToolOutcomeStatus(
    _adeleMap408['status'],
  );
  return _contractConstruct(
    'ModelProviderToolOutcome',
    () => ModelProviderToolOutcome(
      callId: _adeleField409,
      content: _adeleField410,
      status: _adeleField411,
    ),
  );
}

const String modelProviderToolProposalTypeId = 'modelProvider.toolProposal';
Map<String, Object?> _encodeModelProviderToolProposal(
  ModelProviderToolProposal _adeleValue418,
) => <String, Object?>{
  'arguments': _contractJsonMap(_adeleValue418.arguments, 'map'),
  'callId': _adeleValue418.callId,
  'name': _adeleValue418.name,
};
ModelProviderToolProposal _decodeModelProviderToolProposal(
  Object? _adeleValue425,
) {
  final _adeleMap426 = _contractMap(
    _adeleValue425,
    'ModelProviderToolProposal',
  );
  _contractFields(_adeleMap426, const {
    'arguments',
    'callId',
    'name',
  }, 'ModelProviderToolProposal');
  final _adeleField427 = _contractJsonMap(
    _adeleMap426['arguments'],
    'arguments',
  );
  final _adeleField428 = _contractString(_adeleMap426['callId'], 'callId');
  final _adeleField429 = _contractString(_adeleMap426['name'], 'name');
  return _contractConstruct(
    'ModelProviderToolProposal',
    () => ModelProviderToolProposal(
      arguments: _adeleField427,
      callId: _adeleField428,
      name: _adeleField429,
    ),
  );
}

const String modelProviderUsageTypeId = 'modelProvider.usage';
Map<String, Object?> _encodeModelProviderUsage(
  ModelProviderUsage _adeleValue436,
) => <String, Object?>{
  'cacheReadTokens': switch (_adeleValue436.cacheReadTokens) {
    final _adeleNonNullValue438? => _adeleNonNullValue438,
    null => null,
  },
  'cacheWriteTokens': switch (_adeleValue436.cacheWriteTokens) {
    final _adeleNonNullValue442? => _adeleNonNullValue442,
    null => null,
  },
  'inputTokens': switch (_adeleValue436.inputTokens) {
    final _adeleNonNullValue446? => _adeleNonNullValue446,
    null => null,
  },
  'outputTokens': switch (_adeleValue436.outputTokens) {
    final _adeleNonNullValue450? => _adeleNonNullValue450,
    null => null,
  },
  'providerDetails': _contractJsonMap(_adeleValue436.providerDetails, 'map'),
};
ModelProviderUsage _decodeModelProviderUsage(Object? _adeleValue455) {
  final _adeleMap456 = _contractMap(_adeleValue455, 'ModelProviderUsage');
  _contractFields(_adeleMap456, const {
    'cacheReadTokens',
    'cacheWriteTokens',
    'inputTokens',
    'outputTokens',
    'providerDetails',
  }, 'ModelProviderUsage');
  final _adeleField457 = switch (_adeleMap456['cacheReadTokens']) {
    final _adeleNonNullValue463? => _contractInt(
      _adeleNonNullValue463,
      'cacheReadTokens',
    ),
    null => null,
  };
  final _adeleField458 = switch (_adeleMap456['cacheWriteTokens']) {
    final _adeleNonNullValue467? => _contractInt(
      _adeleNonNullValue467,
      'cacheWriteTokens',
    ),
    null => null,
  };
  final _adeleField459 = switch (_adeleMap456['inputTokens']) {
    final _adeleNonNullValue471? => _contractInt(
      _adeleNonNullValue471,
      'inputTokens',
    ),
    null => null,
  };
  final _adeleField460 = switch (_adeleMap456['outputTokens']) {
    final _adeleNonNullValue475? => _contractInt(
      _adeleNonNullValue475,
      'outputTokens',
    ),
    null => null,
  };
  final _adeleField461 = _contractJsonMap(
    _adeleMap456['providerDetails'],
    'providerDetails',
  );
  return _contractConstruct(
    'ModelProviderUsage',
    () => ModelProviderUsage(
      cacheReadTokens: _adeleField457,
      cacheWriteTokens: _adeleField458,
      inputTokens: _adeleField459,
      outputTokens: _adeleField460,
      providerDetails: _adeleField461,
    ),
  );
}

ModelProviderContentKind _decodeModelProviderContentKind(
  Object? _adeleValue480,
) {
  if (_adeleValue480 is! String)
    throw AdeleProtocolException('Expected ModelProviderContentKind.');
  return switch (_adeleValue480) {
    'text' => ModelProviderContentKind.text,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderContentKind: ' + _adeleValue480 + '.',
    ),
  };
}

ModelProviderEventKind _decodeModelProviderEventKind(Object? _adeleValue481) {
  if (_adeleValue481 is! String)
    throw AdeleProtocolException('Expected ModelProviderEventKind.');
  return switch (_adeleValue481) {
    'observation' => ModelProviderEventKind.observation,
    'output' => ModelProviderEventKind.output,
    'terminal' => ModelProviderEventKind.terminal,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderEventKind: ' + _adeleValue481 + '.',
    ),
  };
}

ModelProviderFailureKind _decodeModelProviderFailureKind(
  Object? _adeleValue482,
) {
  if (_adeleValue482 is! String)
    throw AdeleProtocolException('Expected ModelProviderFailureKind.');
  return switch (_adeleValue482) {
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
      'Unknown ModelProviderFailureKind: ' + _adeleValue482 + '.',
    ),
  };
}

ModelProviderIncompleteReason _decodeModelProviderIncompleteReason(
  Object? _adeleValue483,
) {
  if (_adeleValue483 is! String)
    throw AdeleProtocolException('Expected ModelProviderIncompleteReason.');
  return switch (_adeleValue483) {
    'outputLimit' => ModelProviderIncompleteReason.outputLimit,
    'contextLimit' => ModelProviderIncompleteReason.contextLimit,
    'other' => ModelProviderIncompleteReason.other,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderIncompleteReason: ' + _adeleValue483 + '.',
    ),
  };
}

ModelProviderInputKind _decodeModelProviderInputKind(Object? _adeleValue484) {
  if (_adeleValue484 is! String)
    throw AdeleProtocolException('Expected ModelProviderInputKind.');
  return switch (_adeleValue484) {
    'message' => ModelProviderInputKind.message,
    'toolProposal' => ModelProviderInputKind.toolProposal,
    'toolOutcome' => ModelProviderInputKind.toolOutcome,
    'nativeItem' => ModelProviderInputKind.nativeItem,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderInputKind: ' + _adeleValue484 + '.',
    ),
  };
}

ModelProviderMessageRole _decodeModelProviderMessageRole(
  Object? _adeleValue485,
) {
  if (_adeleValue485 is! String)
    throw AdeleProtocolException('Expected ModelProviderMessageRole.');
  return switch (_adeleValue485) {
    'user' => ModelProviderMessageRole.user,
    'assistant' => ModelProviderMessageRole.assistant,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderMessageRole: ' + _adeleValue485 + '.',
    ),
  };
}

ModelProviderObservationKind _decodeModelProviderObservationKind(
  Object? _adeleValue486,
) {
  if (_adeleValue486 is! String)
    throw AdeleProtocolException('Expected ModelProviderObservationKind.');
  return switch (_adeleValue486) {
    'textDelta' => ModelProviderObservationKind.textDelta,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderObservationKind: ' + _adeleValue486 + '.',
    ),
  };
}

ModelProviderOutputKind _decodeModelProviderOutputKind(Object? _adeleValue487) {
  if (_adeleValue487 is! String)
    throw AdeleProtocolException('Expected ModelProviderOutputKind.');
  return switch (_adeleValue487) {
    'text' => ModelProviderOutputKind.text,
    'toolProposal' => ModelProviderOutputKind.toolProposal,
    'nativeItem' => ModelProviderOutputKind.nativeItem,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderOutputKind: ' + _adeleValue487 + '.',
    ),
  };
}

ModelProviderSettlement _decodeModelProviderSettlement(Object? _adeleValue488) {
  if (_adeleValue488 is! String)
    throw AdeleProtocolException('Expected ModelProviderSettlement.');
  return switch (_adeleValue488) {
    'completed' => ModelProviderSettlement.completed,
    'incomplete' => ModelProviderSettlement.incomplete,
    'refused' => ModelProviderSettlement.refused,
    'failed' => ModelProviderSettlement.failed,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderSettlement: ' + _adeleValue488 + '.',
    ),
  };
}

ModelProviderToolChoice _decodeModelProviderToolChoice(Object? _adeleValue489) {
  if (_adeleValue489 is! String)
    throw AdeleProtocolException('Expected ModelProviderToolChoice.');
  return switch (_adeleValue489) {
    'auto' => ModelProviderToolChoice.auto,
    'none' => ModelProviderToolChoice.none,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderToolChoice: ' + _adeleValue489 + '.',
    ),
  };
}

ModelProviderToolOutcomeStatus _decodeModelProviderToolOutcomeStatus(
  Object? _adeleValue490,
) {
  if (_adeleValue490 is! String)
    throw AdeleProtocolException('Expected ModelProviderToolOutcomeStatus.');
  return switch (_adeleValue490) {
    'success' => ModelProviderToolOutcomeStatus.success,
    'rejected' => ModelProviderToolOutcomeStatus.rejected,
    'failed' => ModelProviderToolOutcomeStatus.failed,
    'cancelled' => ModelProviderToolOutcomeStatus.cancelled,
    'indeterminate' => ModelProviderToolOutcomeStatus.indeterminate,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderToolOutcomeStatus: ' + _adeleValue490 + '.',
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
