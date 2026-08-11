// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, use_null_aware_elements

part of 'scripted_model_contract.dart';

const String scriptedModelFixtureServiceId = 'scriptedModelFixture';
const String scriptedModelFixtureServiceInvokeId =
    'scriptedModelFixture.invoke';
const String scriptedModelFixtureServiceInvokeStreamId =
    'scriptedModelFixture.invokeStream';
const String scriptedModelFixtureServiceResetStreamProbeId =
    'scriptedModelFixture.resetStreamProbe';
const String scriptedModelFixtureServiceStreamProbeId =
    'scriptedModelFixture.streamProbe';

final class ScriptedModelFixtureServiceClient
    implements ScriptedModelFixtureService {
  const ScriptedModelFixtureServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<ScriptedModelResponse> invoke(ScriptedModelRequest request) async {
    try {
      return _decodeScriptedModelResponse(
        await this._adeleChannel.request(
          scriptedModelFixtureServiceInvokeId,
          <String, Object?>{'request': _encodeScriptedModelRequest(request)},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError0) {
      switch (_adeleError0.declaredFailureType) {
        case scriptedModelFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError0.details,
            'failure details',
          );
          throw _contractConstruct(
            'ScriptedModelFailure',
            () => ScriptedModelFailure(
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
  Stream<ScriptedModelStreamItem> invokeStream(ScriptedModelRequest request) =>
      AdeleLazyStream<ScriptedModelStreamItem>((
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
        final _adeleRaw6 = _adeleStreamChannel4.stream(
          scriptedModelFixtureServiceInvokeStreamId,
          <String, Object?>{'request': _encodeScriptedModelRequest(request)},
        );
        return _adeleRaw6
            .map<ScriptedModelStreamItem>(
              (Object? _adeleItem5) =>
                  _decodeScriptedModelStreamItem(_adeleItem5),
            )
            .handleError((Object _adeleError5) {
              if (_adeleError5 is AdeleRemoteFailure) {
                switch (_adeleError5.declaredFailureType) {
                  case scriptedModelFailureTypeId:
                    final _adeleDetails8 = _contractJsonMap(
                      _adeleError5.details,
                      'failure details',
                    );
                    throw _contractConstruct(
                      'ScriptedModelFailure',
                      () => ScriptedModelFailure(
                        code: _adeleError5.code,
                        message: _adeleError5.message,
                        details: _adeleDetails8,
                      ),
                    );
                  default:
                    break;
                }
              }
              throw _adeleError5;
            })
            .listen(
              _adeleOnData0,
              onError: _adeleOnError1,
              onDone: _adeleOnDone2,
              cancelOnError: _adeleCancelOnError3,
            );
      });
  @override
  Future<ScriptedModelStreamProbe> resetStreamProbe() async {
    try {
      return _decodeScriptedModelStreamProbe(
        await this._adeleChannel.request(
          scriptedModelFixtureServiceResetStreamProbeId,
          <String, Object?>{},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError11) {
      switch (_adeleError11.declaredFailureType) {
        case scriptedModelFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError11.details,
            'failure details',
          );
          throw _contractConstruct(
            'ScriptedModelFailure',
            () => ScriptedModelFailure(
              code: _adeleError11.code,
              message: _adeleError11.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<ScriptedModelStreamProbe> streamProbe() async {
    try {
      return _decodeScriptedModelStreamProbe(
        await this._adeleChannel.request(
          scriptedModelFixtureServiceStreamProbeId,
          <String, Object?>{},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError14) {
      switch (_adeleError14.declaredFailureType) {
        case scriptedModelFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError14.details,
            'failure details',
          );
          throw _contractConstruct(
            'ScriptedModelFailure',
            () => ScriptedModelFailure(
              code: _adeleError14.code,
              message: _adeleError14.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class ScriptedModelFixtureServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class ScriptedModelFixtureServiceDispatcher
    implements ScriptedModelFixtureServiceRequestDispatcher {
  ScriptedModelFixtureServiceDispatcher(this._adeleService);
  final ScriptedModelFixtureService _adeleService;
  final Map<int, _ContractStreamState> _adeleStreams =
      <int, _ContractStreamState>{};
  final AdeleBoundedExecutor _adeleExecutor = AdeleBoundedExecutor();
  bool _adeleClosed = false;
  @override
  Future<Map<String, Object?>> dispatch(
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
      scriptedModelFixtureServiceInvokeId,
      scriptedModelFixtureServiceResetStreamProbeId,
      scriptedModelFixtureServiceStreamProbeId,
    }.contains(_adeleMethod2))
      return _contractFailure(
        _adeleRequestId1,
        null,
        const {
              scriptedModelFixtureServiceInvokeStreamId,
            }.contains(_adeleMethod2)
            ? 'wrong_method_kind'
            : 'unknown_method',
        const {
              scriptedModelFixtureServiceInvokeStreamId,
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
        scriptedModelFixtureServiceInvokeId => (() {
          _contractFields(_adelePayload4, const {'request'}, 'invoke payload');
          return <Object?>[
            _decodeScriptedModelRequest(_adelePayload4['request']),
          ];
        })(),
        scriptedModelFixtureServiceResetStreamProbeId => (() {
          _contractFields(_adelePayload4, const {}, 'resetStreamProbe payload');
          return <Object?>[];
        })(),
        scriptedModelFixtureServiceStreamProbeId => (() {
          _contractFields(_adelePayload4, const {}, 'streamProbe payload');
          return <Object?>[];
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
        scriptedModelFixtureServiceInvokeId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.invoke(
            _adeleValues0[0] as ScriptedModelRequest,
          );
        })(),
        scriptedModelFixtureServiceResetStreamProbeId => (() async {
          return await this._adeleService.resetStreamProbe();
        })(),
        scriptedModelFixtureServiceStreamProbeId => (() async {
          return await this._adeleService.streamProbe();
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on ScriptedModelFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          scriptedModelFailureTypeId,
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
        scriptedModelFixtureServiceInvokeId => _encodeScriptedModelResponse(
          (_adeleResult8 as ScriptedModelResponse),
        ),
        scriptedModelFixtureServiceResetStreamProbeId =>
          _encodeScriptedModelStreamProbe(
            (_adeleResult8 as ScriptedModelStreamProbe),
          ),
        scriptedModelFixtureServiceStreamProbeId =>
          _encodeScriptedModelStreamProbe(
            (_adeleResult8 as ScriptedModelStreamProbe),
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
  ) async {
    final _adeleKind2 = _adeleCommand0['kind'];
    if (_adeleKind2 == 'request') {
      await _adeleExecutor.run<void>(
        () async => _adeleSend1(await dispatch(_adeleCommand0)),
      );
      return;
    }
    if (_adeleKind2 == 'streamOpen') {
      await _adeleExecutor.run<void>(
        () => _adeleOpenStream(_adeleCommand0, _adeleSend1),
      );
      return;
    }
    final _adeleRequestId3 = _adeleCommand0['requestId'];
    if (_adeleRequestId3 is! int) return;
    final _adeleState4 = _adeleStreams[_adeleRequestId3];
    if (_adeleKind2 == 'streamCredit') {
      final _adeleCredit5 = _adeleCommand0['credit'];
      if (_adeleState4 != null && _adeleCredit5 is int && _adeleCredit5 > 0) {
        _adeleState4.credit += _adeleCredit5;
        _adelePump(_adeleState4, _adeleSend1);
      }
    } else if (_adeleKind2 == 'streamCancel' &&
        await _adeleCancel(_adeleRequestId3)) {
      _adeleSend1({'kind': 'streamCancelled', 'requestId': _adeleRequestId3});
    }
  }

  Future<void> _adeleOpenStream(
    Map<Object?, Object?> _adeleRequest0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    final _adeleRequestId2 = _adeleRequest0['requestId'];
    if (_adeleClosed ||
        _adeleRequestId2 is! int ||
        _adeleStreams.containsKey(_adeleRequestId2)) {
      _adeleSend1(
        _contractStreamFailure(
          _adeleRequestId2,
          null,
          'invalid_request',
          'Malformed stream-open request.',
          const {},
        ),
      );
      return;
    }
    late final String _adeleMethod3;
    late final Map<Object?, Object?> _adelePayload4;
    late final List<Object?> _adeleArguments5;
    try {
      _adeleMethod3 = _decodeContractEnvelope(_adeleRequest0, 'streamOpen');
      if (!const {
        scriptedModelFixtureServiceInvokeStreamId,
      }.contains(_adeleMethod3)) {
        final _adeleWrongKind6 = const {
          scriptedModelFixtureServiceInvokeId,
          scriptedModelFixtureServiceResetStreamProbeId,
          scriptedModelFixtureServiceStreamProbeId,
        }.contains(_adeleMethod3);
        _adeleSend1(
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
        scriptedModelFixtureServiceInvokeStreamId => (() {
          _contractFields(_adelePayload4, const {
            'request',
          }, 'invokeStream payload');
          return <Object?>[
            _decodeScriptedModelRequest(_adelePayload4['request']),
          ];
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on AdeleProtocolException catch (_adeleError7) {
      _adeleSend1(
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
        scriptedModelFixtureServiceInvokeStreamId =>
          this._adeleService
              .invokeStream(_adeleArguments5[0] as ScriptedModelRequest)
              .map<Object?>((Object? _adeleItem) => _adeleItem),
        _ => throw const _ContractUnknownMethod(),
      };
      final _adeleState9 = _ContractStreamState(
        _adeleRequestId2,
        _adeleMethod3,
        AdeleStreamIterator<Object?>(_adeleSource8),
      );
      _adeleStreams[_adeleRequestId2] = _adeleState9;
    } on Object {
      _adeleSend1(
        _contractStreamFailure(
          _adeleRequestId2,
          null,
          'internal_error',
          'The backend stream failed unexpectedly.',
          const {},
        ),
      );
    }
  }

  Future<void> _adelePump(
    _ContractStreamState _adeleState0,
    void Function(Map<String, Object?>) _adeleSend1,
  ) async {
    if (_adeleState0.pumping || _adeleState0.done) return;
    _adeleState0.pumping = true;
    try {
      while (!_adeleState0.done && _adeleState0.credit > 0) {
        _adeleState0.credit--;
        late final bool _adeleHasItem2;
        try {
          _adeleHasItem2 = await _adeleState0.iterator.moveNext();
        } on ScriptedModelFailure catch (_adeleError3) {
          try {
            _adeleFinish(
              _adeleState0,
              _adeleSend1,
              _contractStreamFailure(
                _adeleState0.requestId,
                scriptedModelFailureTypeId,
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
            scriptedModelFixtureServiceInvokeStreamId =>
              _encodeScriptedModelStreamItem(
                (_adeleState0.iterator.current as ScriptedModelStreamItem),
              ),
            _ => throw const _ContractUnknownMethod(),
          };
          _adeleSend1({
            'kind': 'streamItem',
            'requestId': _adeleState0.requestId,
            'payload': _adeleEncoded4,
          });
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
          return;
        }
      }
    } finally {
      _adeleState0.pumping = false;
      if (!_adeleState0.done && _adeleState0.credit > 0)
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

  Future<bool> _adeleCancel(int _adeleRequestId0) async {
    final _adeleState1 = _adeleStreams.remove(_adeleRequestId0);
    if (_adeleState1 == null || _adeleState1.done) return false;
    _adeleState1.done = true;
    await _adeleState1.iterator.cancel();
    return true;
  }

  @override
  Future<void> close() async {
    if (_adeleClosed) return;
    _adeleClosed = true;
    final _adeleIds0 = _adeleStreams.keys.toList(growable: false);
    for (final _adeleId1 in _adeleIds0) {
      await _adeleCancel(_adeleId1);
    }
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
  _ContractStreamState(this.requestId, this.method, this.iterator);
  final int requestId;
  final String method;
  final AdeleStreamIterator<Object?> iterator;
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
const String scriptedModelFailureTypeId = 'scriptedModelFixture.failure';
const String scriptedModelMessageTypeId = 'scriptedModelFixture.message';
Map<String, Object?> _encodeScriptedModelMessage(
  ScriptedModelMessage _adeleValue29,
) => <String, Object?>{
  'content': _adeleValue29.content,
  'role': _adeleValue29.role.name,
  'toolCallId': switch (_adeleValue29.toolCallId) {
    final _adeleNonNullValue35? => _adeleNonNullValue35,
    null => null,
  },
  'toolOutcome': switch (_adeleValue29.toolOutcome) {
    final _adeleNonNullValue39? => _adeleNonNullValue39.name,
    null => null,
  },
  'toolProposal': switch (_adeleValue29.toolProposal) {
    final _adeleNonNullValue43? => _encodeScriptedToolCall(
      _adeleNonNullValue43,
    ),
    null => null,
  },
};
ScriptedModelMessage _decodeScriptedModelMessage(Object? _adeleValue46) {
  final _adeleMap47 = _contractMap(_adeleValue46, 'ScriptedModelMessage');
  _contractFields(_adeleMap47, const {
    'content',
    'role',
    'toolCallId',
    'toolOutcome',
    'toolProposal',
  }, 'ScriptedModelMessage');
  final _adeleField48 = _contractString(_adeleMap47['content'], 'content');
  final _adeleField49 = _decodeScriptedModelMessageRole(_adeleMap47['role']);
  final _adeleField50 = switch (_adeleMap47['toolCallId']) {
    final _adeleNonNullValue58? => _contractString(
      _adeleNonNullValue58,
      'toolCallId',
    ),
    null => null,
  };
  final _adeleField51 = switch (_adeleMap47['toolOutcome']) {
    final _adeleNonNullValue62? => _decodeScriptedToolOutcomeStatus(
      _adeleNonNullValue62,
    ),
    null => null,
  };
  final _adeleField52 = switch (_adeleMap47['toolProposal']) {
    final _adeleNonNullValue66? => _decodeScriptedToolCall(
      _adeleNonNullValue66,
    ),
    null => null,
  };
  return _contractConstruct(
    'ScriptedModelMessage',
    () => ScriptedModelMessage(
      content: _adeleField48,
      role: _adeleField49,
      toolCallId: _adeleField50,
      toolOutcome: _adeleField51,
      toolProposal: _adeleField52,
    ),
  );
}

const String scriptedModelRequestTypeId = 'scriptedModelFixture.request';
Map<String, Object?> _encodeScriptedModelRequest(
  ScriptedModelRequest _adeleValue69,
) => <String, Object?>{
  'messages': _adeleValue69.messages
      .map((_adeleElement70) => _encodeScriptedModelMessage(_adeleElement70))
      .toList(growable: false),
  'tools': _adeleValue69.tools
      .map((_adeleElement74) => _encodeScriptedToolDefinition(_adeleElement74))
      .toList(growable: false),
};
ScriptedModelRequest _decodeScriptedModelRequest(Object? _adeleValue78) {
  final _adeleMap79 = _contractMap(_adeleValue78, 'ScriptedModelRequest');
  _contractFields(_adeleMap79, const {
    'messages',
    'tools',
  }, 'ScriptedModelRequest');
  final _adeleField80 = List<ScriptedModelMessage>.unmodifiable(
    _contractList(
      _adeleMap79['messages'],
      'messages',
    ).map((_adeleElement82) => _decodeScriptedModelMessage(_adeleElement82)),
  );
  final _adeleField81 = List<ScriptedToolDefinition>.unmodifiable(
    _contractList(
      _adeleMap79['tools'],
      'tools',
    ).map((_adeleElement86) => _decodeScriptedToolDefinition(_adeleElement86)),
  );
  return _contractConstruct(
    'ScriptedModelRequest',
    () => ScriptedModelRequest(messages: _adeleField80, tools: _adeleField81),
  );
}

const String scriptedModelResponseTypeId = 'scriptedModelFixture.response';
Map<String, Object?> _encodeScriptedModelResponse(
  ScriptedModelResponse _adeleValue90,
) => <String, Object?>{
  'content': _adeleValue90.content,
  'toolCall': switch (_adeleValue90.toolCall) {
    final _adeleNonNullValue94? => _encodeScriptedToolCall(
      _adeleNonNullValue94,
    ),
    null => null,
  },
};
ScriptedModelResponse _decodeScriptedModelResponse(Object? _adeleValue97) {
  final _adeleMap98 = _contractMap(_adeleValue97, 'ScriptedModelResponse');
  _contractFields(_adeleMap98, const {
    'content',
    'toolCall',
  }, 'ScriptedModelResponse');
  final _adeleField99 = _contractString(_adeleMap98['content'], 'content');
  final _adeleField100 = switch (_adeleMap98['toolCall']) {
    final _adeleNonNullValue104? => _decodeScriptedToolCall(
      _adeleNonNullValue104,
    ),
    null => null,
  };
  return _contractConstruct(
    'ScriptedModelResponse',
    () =>
        ScriptedModelResponse(content: _adeleField99, toolCall: _adeleField100),
  );
}

const String scriptedModelStreamItemTypeId = 'scriptedModelFixture.streamItem';
Map<String, Object?> _encodeScriptedModelStreamItem(
  ScriptedModelStreamItem _adeleValue107,
) => <String, Object?>{
  'kind': _adeleValue107.kind.name,
  'sequence': switch (_adeleValue107.sequence) {
    final _adeleNonNullValue111? => _adeleNonNullValue111,
    null => null,
  },
  'text': switch (_adeleValue107.text) {
    final _adeleNonNullValue115? => _adeleNonNullValue115,
    null => null,
  },
  'toolCall': switch (_adeleValue107.toolCall) {
    final _adeleNonNullValue119? => _encodeScriptedToolCall(
      _adeleNonNullValue119,
    ),
    null => null,
  },
};
ScriptedModelStreamItem _decodeScriptedModelStreamItem(Object? _adeleValue122) {
  final _adeleMap123 = _contractMap(_adeleValue122, 'ScriptedModelStreamItem');
  _contractFields(_adeleMap123, const {
    'kind',
    'sequence',
    'text',
    'toolCall',
  }, 'ScriptedModelStreamItem');
  final _adeleField124 = _decodeScriptedModelStreamItemKind(
    _adeleMap123['kind'],
  );
  final _adeleField125 = switch (_adeleMap123['sequence']) {
    final _adeleNonNullValue131? => _contractInt(
      _adeleNonNullValue131,
      'sequence',
    ),
    null => null,
  };
  final _adeleField126 = switch (_adeleMap123['text']) {
    final _adeleNonNullValue135? => _contractString(
      _adeleNonNullValue135,
      'text',
    ),
    null => null,
  };
  final _adeleField127 = switch (_adeleMap123['toolCall']) {
    final _adeleNonNullValue139? => _decodeScriptedToolCall(
      _adeleNonNullValue139,
    ),
    null => null,
  };
  return _contractConstruct(
    'ScriptedModelStreamItem',
    () => ScriptedModelStreamItem(
      kind: _adeleField124,
      sequence: _adeleField125,
      text: _adeleField126,
      toolCall: _adeleField127,
    ),
  );
}

const String scriptedModelStreamProbeTypeId =
    'scriptedModelFixture.streamProbe';
Map<String, Object?> _encodeScriptedModelStreamProbe(
  ScriptedModelStreamProbe _adeleValue142,
) => <String, Object?>{
  'active': _adeleValue142.active,
  'advanced': _adeleValue142.advanced,
  'cancellations': _adeleValue142.cancellations,
};
ScriptedModelStreamProbe _decodeScriptedModelStreamProbe(
  Object? _adeleValue149,
) {
  final _adeleMap150 = _contractMap(_adeleValue149, 'ScriptedModelStreamProbe');
  _contractFields(_adeleMap150, const {
    'active',
    'advanced',
    'cancellations',
  }, 'ScriptedModelStreamProbe');
  final _adeleField151 = _contractInt(_adeleMap150['active'], 'active');
  final _adeleField152 = _contractInt(_adeleMap150['advanced'], 'advanced');
  final _adeleField153 = _contractInt(
    _adeleMap150['cancellations'],
    'cancellations',
  );
  return _contractConstruct(
    'ScriptedModelStreamProbe',
    () => ScriptedModelStreamProbe(
      active: _adeleField151,
      advanced: _adeleField152,
      cancellations: _adeleField153,
    ),
  );
}

const String scriptedToolCallTypeId = 'scriptedModelFixture.toolCall';
Map<String, Object?> _encodeScriptedToolCall(ScriptedToolCall _adeleValue160) =>
    <String, Object?>{
      'arguments': _contractJsonMap(_adeleValue160.arguments, 'map'),
      'id': _adeleValue160.id,
      'name': _adeleValue160.name,
    };
ScriptedToolCall _decodeScriptedToolCall(Object? _adeleValue167) {
  final _adeleMap168 = _contractMap(_adeleValue167, 'ScriptedToolCall');
  _contractFields(_adeleMap168, const {
    'arguments',
    'id',
    'name',
  }, 'ScriptedToolCall');
  final _adeleField169 = _contractJsonMap(
    _adeleMap168['arguments'],
    'arguments',
  );
  final _adeleField170 = _contractString(_adeleMap168['id'], 'id');
  final _adeleField171 = _contractString(_adeleMap168['name'], 'name');
  return _contractConstruct(
    'ScriptedToolCall',
    () => ScriptedToolCall(
      arguments: _adeleField169,
      id: _adeleField170,
      name: _adeleField171,
    ),
  );
}

const String scriptedToolDefinitionTypeId =
    'scriptedModelFixture.toolDefinition';
Map<String, Object?> _encodeScriptedToolDefinition(
  ScriptedToolDefinition _adeleValue178,
) => <String, Object?>{
  'argumentsSchema': _contractJsonMap(_adeleValue178.argumentsSchema, 'map'),
  'description': _adeleValue178.description,
  'name': _adeleValue178.name,
};
ScriptedToolDefinition _decodeScriptedToolDefinition(Object? _adeleValue185) {
  final _adeleMap186 = _contractMap(_adeleValue185, 'ScriptedToolDefinition');
  _contractFields(_adeleMap186, const {
    'argumentsSchema',
    'description',
    'name',
  }, 'ScriptedToolDefinition');
  final _adeleField187 = _contractJsonMap(
    _adeleMap186['argumentsSchema'],
    'argumentsSchema',
  );
  final _adeleField188 = _contractString(
    _adeleMap186['description'],
    'description',
  );
  final _adeleField189 = _contractString(_adeleMap186['name'], 'name');
  return _contractConstruct(
    'ScriptedToolDefinition',
    () => ScriptedToolDefinition(
      argumentsSchema: _adeleField187,
      description: _adeleField188,
      name: _adeleField189,
    ),
  );
}

ScriptedModelMessageRole _decodeScriptedModelMessageRole(
  Object? _adeleValue196,
) {
  if (_adeleValue196 is! String)
    throw AdeleProtocolException('Expected ScriptedModelMessageRole.');
  return switch (_adeleValue196) {
    'user' => ScriptedModelMessageRole.user,
    'assistant' => ScriptedModelMessageRole.assistant,
    'tool' => ScriptedModelMessageRole.tool,
    _ => throw AdeleProtocolException(
      'Unknown ScriptedModelMessageRole: ' + _adeleValue196 + '.',
    ),
  };
}

ScriptedModelStreamItemKind _decodeScriptedModelStreamItemKind(
  Object? _adeleValue197,
) {
  if (_adeleValue197 is! String)
    throw AdeleProtocolException('Expected ScriptedModelStreamItemKind.');
  return switch (_adeleValue197) {
    'text' => ScriptedModelStreamItemKind.text,
    'toolCall' => ScriptedModelStreamItemKind.toolCall,
    'probe' => ScriptedModelStreamItemKind.probe,
    _ => throw AdeleProtocolException(
      'Unknown ScriptedModelStreamItemKind: ' + _adeleValue197 + '.',
    ),
  };
}

ScriptedToolOutcomeStatus _decodeScriptedToolOutcomeStatus(
  Object? _adeleValue198,
) {
  if (_adeleValue198 is! String)
    throw AdeleProtocolException('Expected ScriptedToolOutcomeStatus.');
  return switch (_adeleValue198) {
    'success' => ScriptedToolOutcomeStatus.success,
    'userRejected' => ScriptedToolOutcomeStatus.userRejected,
    'policyDenied' => ScriptedToolOutcomeStatus.policyDenied,
    'failure' => ScriptedToolOutcomeStatus.failure,
    'cancelled' => ScriptedToolOutcomeStatus.cancelled,
    'indeterminate' => ScriptedToolOutcomeStatus.indeterminate,
    _ => throw AdeleProtocolException(
      'Unknown ScriptedToolOutcomeStatus: ' + _adeleValue198 + '.',
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
