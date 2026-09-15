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

const String modelProviderNativePresentationTypeId =
    'modelProvider.nativePresentation';
Map<String, Object?> _encodeModelProviderNativePresentation(
  ModelProviderNativePresentation _adeleValue177,
) => <String, Object?>{
  'compactText': _adeleValue177.compactText,
  'data': _contractJsonMap(_adeleValue177.data, 'map'),
  'kind': _adeleValue177.kind,
};
ModelProviderNativePresentation _decodeModelProviderNativePresentation(
  Object? _adeleValue184,
) {
  final _adeleMap185 = _contractMap(
    _adeleValue184,
    'ModelProviderNativePresentation',
  );
  _contractFields(_adeleMap185, const {
    'compactText',
    'data',
    'kind',
  }, 'ModelProviderNativePresentation');
  final _adeleField186 = _contractString(
    _adeleMap185['compactText'],
    'compactText',
  );
  final _adeleField187 = _contractJsonMap(_adeleMap185['data'], 'data');
  final _adeleField188 = _contractString(_adeleMap185['kind'], 'kind');
  return _contractConstruct(
    'ModelProviderNativePresentation',
    () => ModelProviderNativePresentation(
      compactText: _adeleField186,
      data: _adeleField187,
      kind: _adeleField188,
    ),
  );
}

const String modelProviderObservationTypeId = 'modelProvider.observation';
Map<String, Object?> _encodeModelProviderObservation(
  ModelProviderObservation _adeleValue195,
) => <String, Object?>{
  'itemId': switch (_adeleValue195.itemId) {
    final _adeleNonNullValue197? => _adeleNonNullValue197,
    null => null,
  },
  'kind': _adeleValue195.kind.name,
  'textDelta': _adeleValue195.textDelta,
};
ModelProviderObservation _decodeModelProviderObservation(
  Object? _adeleValue204,
) {
  final _adeleMap205 = _contractMap(_adeleValue204, 'ModelProviderObservation');
  _contractFields(_adeleMap205, const {
    'itemId',
    'kind',
    'textDelta',
  }, 'ModelProviderObservation');
  final _adeleField206 = switch (_adeleMap205['itemId']) {
    final _adeleNonNullValue210? => _contractString(
      _adeleNonNullValue210,
      'itemId',
    ),
    null => null,
  };
  final _adeleField207 = _decodeModelProviderObservationKind(
    _adeleMap205['kind'],
  );
  final _adeleField208 = _contractString(
    _adeleMap205['textDelta'],
    'textDelta',
  );
  return _contractConstruct(
    'ModelProviderObservation',
    () => ModelProviderObservation(
      itemId: _adeleField206,
      kind: _adeleField207,
      textDelta: _adeleField208,
    ),
  );
}

const String modelProviderOutputTypeId = 'modelProvider.output';
Map<String, Object?> _encodeModelProviderOutput(
  ModelProviderOutput _adeleValue217,
) => <String, Object?>{
  'itemId': switch (_adeleValue217.itemId) {
    final _adeleNonNullValue219? => _adeleNonNullValue219,
    null => null,
  },
  'kind': _adeleValue217.kind.name,
  'nativeMetadata': switch (_adeleValue217.nativeMetadata) {
    final _adeleNonNullValue225? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue225,
    ),
    null => null,
  },
  'nativePresentation': switch (_adeleValue217.nativePresentation) {
    final _adeleNonNullValue229? => _encodeModelProviderNativePresentation(
      _adeleNonNullValue229,
    ),
    null => null,
  },
  'text': switch (_adeleValue217.text) {
    final _adeleNonNullValue233? => _adeleNonNullValue233,
    null => null,
  },
  'toolProposal': switch (_adeleValue217.toolProposal) {
    final _adeleNonNullValue237? => _encodeModelProviderToolProposal(
      _adeleNonNullValue237,
    ),
    null => null,
  },
};
ModelProviderOutput _decodeModelProviderOutput(Object? _adeleValue240) {
  final _adeleMap241 = _contractMap(_adeleValue240, 'ModelProviderOutput');
  _contractFields(_adeleMap241, const {
    'itemId',
    'kind',
    'nativeMetadata',
    'nativePresentation',
    'text',
    'toolProposal',
  }, 'ModelProviderOutput');
  final _adeleField242 = switch (_adeleMap241['itemId']) {
    final _adeleNonNullValue249? => _contractString(
      _adeleNonNullValue249,
      'itemId',
    ),
    null => null,
  };
  final _adeleField243 = _decodeModelProviderOutputKind(_adeleMap241['kind']);
  final _adeleField244 = switch (_adeleMap241['nativeMetadata']) {
    final _adeleNonNullValue255? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue255,
    ),
    null => null,
  };
  final _adeleField245 = switch (_adeleMap241['nativePresentation']) {
    final _adeleNonNullValue259? => _decodeModelProviderNativePresentation(
      _adeleNonNullValue259,
    ),
    null => null,
  };
  final _adeleField246 = switch (_adeleMap241['text']) {
    final _adeleNonNullValue263? => _contractString(
      _adeleNonNullValue263,
      'text',
    ),
    null => null,
  };
  final _adeleField247 = switch (_adeleMap241['toolProposal']) {
    final _adeleNonNullValue267? => _decodeModelProviderToolProposal(
      _adeleNonNullValue267,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderOutput',
    () => ModelProviderOutput(
      itemId: _adeleField242,
      kind: _adeleField243,
      nativeMetadata: _adeleField244,
      nativePresentation: _adeleField245,
      text: _adeleField246,
      toolProposal: _adeleField247,
    ),
  );
}

const String modelProviderRequestTypeId = 'modelProvider.request';
Map<String, Object?> _encodeModelProviderRequest(
  ModelProviderRequest _adeleValue270,
) => <String, Object?>{
  'input': _adeleValue270.input
      .map((_adeleElement271) => _encodeModelProviderInput(_adeleElement271))
      .toList(growable: false),
  'instructions': _adeleValue270.instructions,
  'maxOutputTokens': switch (_adeleValue270.maxOutputTokens) {
    final _adeleNonNullValue278? => _adeleNonNullValue278,
    null => null,
  },
  'model': _adeleValue270.model,
  'nativeState': switch (_adeleValue270.nativeState) {
    final _adeleNonNullValue284? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue284,
    ),
    null => null,
  },
  'providerOptions': _contractJsonMap(_adeleValue270.providerOptions, 'map'),
  'toolChoice': _adeleValue270.toolChoice.name,
  'tools': _adeleValue270.tools
      .map((_adeleElement291) => _encodeModelProviderTool(_adeleElement291))
      .toList(growable: false),
};
ModelProviderRequest _decodeModelProviderRequest(Object? _adeleValue295) {
  final _adeleMap296 = _contractMap(_adeleValue295, 'ModelProviderRequest');
  _contractFields(_adeleMap296, const {
    'input',
    'instructions',
    'maxOutputTokens',
    'model',
    'nativeState',
    'providerOptions',
    'toolChoice',
    'tools',
  }, 'ModelProviderRequest');
  final _adeleField297 = List<ModelProviderInput>.unmodifiable(
    _contractList(
      _adeleMap296['input'],
      'input',
    ).map((_adeleElement305) => _decodeModelProviderInput(_adeleElement305)),
  );
  final _adeleField298 = _contractString(
    _adeleMap296['instructions'],
    'instructions',
  );
  final _adeleField299 = switch (_adeleMap296['maxOutputTokens']) {
    final _adeleNonNullValue312? => _contractInt(
      _adeleNonNullValue312,
      'maxOutputTokens',
    ),
    null => null,
  };
  final _adeleField300 = _contractString(_adeleMap296['model'], 'model');
  final _adeleField301 = switch (_adeleMap296['nativeState']) {
    final _adeleNonNullValue318? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue318,
    ),
    null => null,
  };
  final _adeleField302 = _contractJsonMap(
    _adeleMap296['providerOptions'],
    'providerOptions',
  );
  final _adeleField303 = _decodeModelProviderToolChoice(
    _adeleMap296['toolChoice'],
  );
  final _adeleField304 = List<ModelProviderTool>.unmodifiable(
    _contractList(
      _adeleMap296['tools'],
      'tools',
    ).map((_adeleElement325) => _decodeModelProviderTool(_adeleElement325)),
  );
  return _contractConstruct(
    'ModelProviderRequest',
    () => ModelProviderRequest(
      input: _adeleField297,
      instructions: _adeleField298,
      maxOutputTokens: _adeleField299,
      model: _adeleField300,
      nativeState: _adeleField301,
      providerOptions: _adeleField302,
      toolChoice: _adeleField303,
      tools: _adeleField304,
    ),
  );
}

const String modelProviderTerminalTypeId = 'modelProvider.terminal';
Map<String, Object?> _encodeModelProviderTerminal(
  ModelProviderTerminal _adeleValue329,
) => <String, Object?>{
  'effectiveModel': switch (_adeleValue329.effectiveModel) {
    final _adeleNonNullValue331? => _adeleNonNullValue331,
    null => null,
  },
  'failure': switch (_adeleValue329.failure) {
    final _adeleNonNullValue335? => _encodeModelProviderFailure(
      _adeleNonNullValue335,
    ),
    null => null,
  },
  'incompleteReason': switch (_adeleValue329.incompleteReason) {
    final _adeleNonNullValue339? => _adeleNonNullValue339.name,
    null => null,
  },
  'nativeState': switch (_adeleValue329.nativeState) {
    final _adeleNonNullValue343? => _encodeModelProviderNativeEnvelope(
      _adeleNonNullValue343,
    ),
    null => null,
  },
  'providerStopReason': switch (_adeleValue329.providerStopReason) {
    final _adeleNonNullValue347? => _adeleNonNullValue347,
    null => null,
  },
  'requestId': switch (_adeleValue329.requestId) {
    final _adeleNonNullValue351? => _adeleNonNullValue351,
    null => null,
  },
  'responseId': switch (_adeleValue329.responseId) {
    final _adeleNonNullValue355? => _adeleNonNullValue355,
    null => null,
  },
  'settlement': _adeleValue329.settlement.name,
  'usage': switch (_adeleValue329.usage) {
    final _adeleNonNullValue361? => _encodeModelProviderUsage(
      _adeleNonNullValue361,
    ),
    null => null,
  },
};
ModelProviderTerminal _decodeModelProviderTerminal(Object? _adeleValue364) {
  final _adeleMap365 = _contractMap(_adeleValue364, 'ModelProviderTerminal');
  _contractFields(_adeleMap365, const {
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
  final _adeleField366 = switch (_adeleMap365['effectiveModel']) {
    final _adeleNonNullValue376? => _contractString(
      _adeleNonNullValue376,
      'effectiveModel',
    ),
    null => null,
  };
  final _adeleField367 = switch (_adeleMap365['failure']) {
    final _adeleNonNullValue380? => _decodeModelProviderFailure(
      _adeleNonNullValue380,
    ),
    null => null,
  };
  final _adeleField368 = switch (_adeleMap365['incompleteReason']) {
    final _adeleNonNullValue384? => _decodeModelProviderIncompleteReason(
      _adeleNonNullValue384,
    ),
    null => null,
  };
  final _adeleField369 = switch (_adeleMap365['nativeState']) {
    final _adeleNonNullValue388? => _decodeModelProviderNativeEnvelope(
      _adeleNonNullValue388,
    ),
    null => null,
  };
  final _adeleField370 = switch (_adeleMap365['providerStopReason']) {
    final _adeleNonNullValue392? => _contractString(
      _adeleNonNullValue392,
      'providerStopReason',
    ),
    null => null,
  };
  final _adeleField371 = switch (_adeleMap365['requestId']) {
    final _adeleNonNullValue396? => _contractString(
      _adeleNonNullValue396,
      'requestId',
    ),
    null => null,
  };
  final _adeleField372 = switch (_adeleMap365['responseId']) {
    final _adeleNonNullValue400? => _contractString(
      _adeleNonNullValue400,
      'responseId',
    ),
    null => null,
  };
  final _adeleField373 = _decodeModelProviderSettlement(
    _adeleMap365['settlement'],
  );
  final _adeleField374 = switch (_adeleMap365['usage']) {
    final _adeleNonNullValue406? => _decodeModelProviderUsage(
      _adeleNonNullValue406,
    ),
    null => null,
  };
  return _contractConstruct(
    'ModelProviderTerminal',
    () => ModelProviderTerminal(
      effectiveModel: _adeleField366,
      failure: _adeleField367,
      incompleteReason: _adeleField368,
      nativeState: _adeleField369,
      providerStopReason: _adeleField370,
      requestId: _adeleField371,
      responseId: _adeleField372,
      settlement: _adeleField373,
      usage: _adeleField374,
    ),
  );
}

const String modelProviderToolTypeId = 'modelProvider.tool';
Map<String, Object?> _encodeModelProviderTool(
  ModelProviderTool _adeleValue409,
) => <String, Object?>{
  'argumentsSchema': _contractJsonMap(_adeleValue409.argumentsSchema, 'map'),
  'description': _adeleValue409.description,
  'name': _adeleValue409.name,
};
ModelProviderTool _decodeModelProviderTool(Object? _adeleValue416) {
  final _adeleMap417 = _contractMap(_adeleValue416, 'ModelProviderTool');
  _contractFields(_adeleMap417, const {
    'argumentsSchema',
    'description',
    'name',
  }, 'ModelProviderTool');
  final _adeleField418 = _contractJsonMap(
    _adeleMap417['argumentsSchema'],
    'argumentsSchema',
  );
  final _adeleField419 = _contractString(
    _adeleMap417['description'],
    'description',
  );
  final _adeleField420 = _contractString(_adeleMap417['name'], 'name');
  return _contractConstruct(
    'ModelProviderTool',
    () => ModelProviderTool(
      argumentsSchema: _adeleField418,
      description: _adeleField419,
      name: _adeleField420,
    ),
  );
}

const String modelProviderToolOutcomeTypeId = 'modelProvider.toolOutcome';
Map<String, Object?> _encodeModelProviderToolOutcome(
  ModelProviderToolOutcome _adeleValue427,
) => <String, Object?>{
  'callId': _adeleValue427.callId,
  'content': _adeleValue427.content,
  'status': _adeleValue427.status.name,
};
ModelProviderToolOutcome _decodeModelProviderToolOutcome(
  Object? _adeleValue434,
) {
  final _adeleMap435 = _contractMap(_adeleValue434, 'ModelProviderToolOutcome');
  _contractFields(_adeleMap435, const {
    'callId',
    'content',
    'status',
  }, 'ModelProviderToolOutcome');
  final _adeleField436 = _contractString(_adeleMap435['callId'], 'callId');
  final _adeleField437 = _contractString(_adeleMap435['content'], 'content');
  final _adeleField438 = _decodeModelProviderToolOutcomeStatus(
    _adeleMap435['status'],
  );
  return _contractConstruct(
    'ModelProviderToolOutcome',
    () => ModelProviderToolOutcome(
      callId: _adeleField436,
      content: _adeleField437,
      status: _adeleField438,
    ),
  );
}

const String modelProviderToolProposalTypeId = 'modelProvider.toolProposal';
Map<String, Object?> _encodeModelProviderToolProposal(
  ModelProviderToolProposal _adeleValue445,
) => <String, Object?>{
  'arguments': _contractJsonMap(_adeleValue445.arguments, 'map'),
  'callId': _adeleValue445.callId,
  'name': _adeleValue445.name,
};
ModelProviderToolProposal _decodeModelProviderToolProposal(
  Object? _adeleValue452,
) {
  final _adeleMap453 = _contractMap(
    _adeleValue452,
    'ModelProviderToolProposal',
  );
  _contractFields(_adeleMap453, const {
    'arguments',
    'callId',
    'name',
  }, 'ModelProviderToolProposal');
  final _adeleField454 = _contractJsonMap(
    _adeleMap453['arguments'],
    'arguments',
  );
  final _adeleField455 = _contractString(_adeleMap453['callId'], 'callId');
  final _adeleField456 = _contractString(_adeleMap453['name'], 'name');
  return _contractConstruct(
    'ModelProviderToolProposal',
    () => ModelProviderToolProposal(
      arguments: _adeleField454,
      callId: _adeleField455,
      name: _adeleField456,
    ),
  );
}

const String modelProviderUsageTypeId = 'modelProvider.usage';
Map<String, Object?> _encodeModelProviderUsage(
  ModelProviderUsage _adeleValue463,
) => <String, Object?>{
  'cacheReadTokens': switch (_adeleValue463.cacheReadTokens) {
    final _adeleNonNullValue465? => _adeleNonNullValue465,
    null => null,
  },
  'cacheWriteTokens': switch (_adeleValue463.cacheWriteTokens) {
    final _adeleNonNullValue469? => _adeleNonNullValue469,
    null => null,
  },
  'inputTokens': switch (_adeleValue463.inputTokens) {
    final _adeleNonNullValue473? => _adeleNonNullValue473,
    null => null,
  },
  'outputTokens': switch (_adeleValue463.outputTokens) {
    final _adeleNonNullValue477? => _adeleNonNullValue477,
    null => null,
  },
  'providerDetails': _contractJsonMap(_adeleValue463.providerDetails, 'map'),
};
ModelProviderUsage _decodeModelProviderUsage(Object? _adeleValue482) {
  final _adeleMap483 = _contractMap(_adeleValue482, 'ModelProviderUsage');
  _contractFields(_adeleMap483, const {
    'cacheReadTokens',
    'cacheWriteTokens',
    'inputTokens',
    'outputTokens',
    'providerDetails',
  }, 'ModelProviderUsage');
  final _adeleField484 = switch (_adeleMap483['cacheReadTokens']) {
    final _adeleNonNullValue490? => _contractInt(
      _adeleNonNullValue490,
      'cacheReadTokens',
    ),
    null => null,
  };
  final _adeleField485 = switch (_adeleMap483['cacheWriteTokens']) {
    final _adeleNonNullValue494? => _contractInt(
      _adeleNonNullValue494,
      'cacheWriteTokens',
    ),
    null => null,
  };
  final _adeleField486 = switch (_adeleMap483['inputTokens']) {
    final _adeleNonNullValue498? => _contractInt(
      _adeleNonNullValue498,
      'inputTokens',
    ),
    null => null,
  };
  final _adeleField487 = switch (_adeleMap483['outputTokens']) {
    final _adeleNonNullValue502? => _contractInt(
      _adeleNonNullValue502,
      'outputTokens',
    ),
    null => null,
  };
  final _adeleField488 = _contractJsonMap(
    _adeleMap483['providerDetails'],
    'providerDetails',
  );
  return _contractConstruct(
    'ModelProviderUsage',
    () => ModelProviderUsage(
      cacheReadTokens: _adeleField484,
      cacheWriteTokens: _adeleField485,
      inputTokens: _adeleField486,
      outputTokens: _adeleField487,
      providerDetails: _adeleField488,
    ),
  );
}

ModelProviderContentKind _decodeModelProviderContentKind(
  Object? _adeleValue507,
) {
  if (_adeleValue507 is! String)
    throw AdeleProtocolException('Expected ModelProviderContentKind.');
  return switch (_adeleValue507) {
    'text' => ModelProviderContentKind.text,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderContentKind: ' + _adeleValue507 + '.',
    ),
  };
}

ModelProviderEventKind _decodeModelProviderEventKind(Object? _adeleValue508) {
  if (_adeleValue508 is! String)
    throw AdeleProtocolException('Expected ModelProviderEventKind.');
  return switch (_adeleValue508) {
    'observation' => ModelProviderEventKind.observation,
    'output' => ModelProviderEventKind.output,
    'terminal' => ModelProviderEventKind.terminal,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderEventKind: ' + _adeleValue508 + '.',
    ),
  };
}

ModelProviderFailureKind _decodeModelProviderFailureKind(
  Object? _adeleValue509,
) {
  if (_adeleValue509 is! String)
    throw AdeleProtocolException('Expected ModelProviderFailureKind.');
  return switch (_adeleValue509) {
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
      'Unknown ModelProviderFailureKind: ' + _adeleValue509 + '.',
    ),
  };
}

ModelProviderIncompleteReason _decodeModelProviderIncompleteReason(
  Object? _adeleValue510,
) {
  if (_adeleValue510 is! String)
    throw AdeleProtocolException('Expected ModelProviderIncompleteReason.');
  return switch (_adeleValue510) {
    'outputLimit' => ModelProviderIncompleteReason.outputLimit,
    'contextLimit' => ModelProviderIncompleteReason.contextLimit,
    'other' => ModelProviderIncompleteReason.other,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderIncompleteReason: ' + _adeleValue510 + '.',
    ),
  };
}

ModelProviderInputKind _decodeModelProviderInputKind(Object? _adeleValue511) {
  if (_adeleValue511 is! String)
    throw AdeleProtocolException('Expected ModelProviderInputKind.');
  return switch (_adeleValue511) {
    'message' => ModelProviderInputKind.message,
    'toolProposal' => ModelProviderInputKind.toolProposal,
    'toolOutcome' => ModelProviderInputKind.toolOutcome,
    'nativeItem' => ModelProviderInputKind.nativeItem,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderInputKind: ' + _adeleValue511 + '.',
    ),
  };
}

ModelProviderMessageRole _decodeModelProviderMessageRole(
  Object? _adeleValue512,
) {
  if (_adeleValue512 is! String)
    throw AdeleProtocolException('Expected ModelProviderMessageRole.');
  return switch (_adeleValue512) {
    'user' => ModelProviderMessageRole.user,
    'assistant' => ModelProviderMessageRole.assistant,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderMessageRole: ' + _adeleValue512 + '.',
    ),
  };
}

ModelProviderObservationKind _decodeModelProviderObservationKind(
  Object? _adeleValue513,
) {
  if (_adeleValue513 is! String)
    throw AdeleProtocolException('Expected ModelProviderObservationKind.');
  return switch (_adeleValue513) {
    'textDelta' => ModelProviderObservationKind.textDelta,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderObservationKind: ' + _adeleValue513 + '.',
    ),
  };
}

ModelProviderOutputKind _decodeModelProviderOutputKind(Object? _adeleValue514) {
  if (_adeleValue514 is! String)
    throw AdeleProtocolException('Expected ModelProviderOutputKind.');
  return switch (_adeleValue514) {
    'text' => ModelProviderOutputKind.text,
    'toolProposal' => ModelProviderOutputKind.toolProposal,
    'nativeItem' => ModelProviderOutputKind.nativeItem,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderOutputKind: ' + _adeleValue514 + '.',
    ),
  };
}

ModelProviderSettlement _decodeModelProviderSettlement(Object? _adeleValue515) {
  if (_adeleValue515 is! String)
    throw AdeleProtocolException('Expected ModelProviderSettlement.');
  return switch (_adeleValue515) {
    'completed' => ModelProviderSettlement.completed,
    'incomplete' => ModelProviderSettlement.incomplete,
    'refused' => ModelProviderSettlement.refused,
    'failed' => ModelProviderSettlement.failed,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderSettlement: ' + _adeleValue515 + '.',
    ),
  };
}

ModelProviderToolChoice _decodeModelProviderToolChoice(Object? _adeleValue516) {
  if (_adeleValue516 is! String)
    throw AdeleProtocolException('Expected ModelProviderToolChoice.');
  return switch (_adeleValue516) {
    'auto' => ModelProviderToolChoice.auto,
    'none' => ModelProviderToolChoice.none,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderToolChoice: ' + _adeleValue516 + '.',
    ),
  };
}

ModelProviderToolOutcomeStatus _decodeModelProviderToolOutcomeStatus(
  Object? _adeleValue517,
) {
  if (_adeleValue517 is! String)
    throw AdeleProtocolException('Expected ModelProviderToolOutcomeStatus.');
  return switch (_adeleValue517) {
    'success' => ModelProviderToolOutcomeStatus.success,
    'rejected' => ModelProviderToolOutcomeStatus.rejected,
    'failed' => ModelProviderToolOutcomeStatus.failed,
    'cancelled' => ModelProviderToolOutcomeStatus.cancelled,
    'indeterminate' => ModelProviderToolOutcomeStatus.indeterminate,
    _ => throw AdeleProtocolException(
      'Unknown ModelProviderToolOutcomeStatus: ' + _adeleValue517 + '.',
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
