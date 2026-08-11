// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, use_null_aware_elements

part of 'scripted_model_contract.dart';

const String scriptedModelFixtureServiceId = 'scriptedModelFixture';
const String scriptedModelFixtureServiceInvokeId =
    'scriptedModelFixture.invoke';

final class ScriptedModelFixtureServiceClient
    implements ScriptedModelFixtureService {
  const ScriptedModelFixtureServiceClient(this._adeleChannel);
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
}

abstract interface class ScriptedModelFixtureServiceRequestDispatcher {
  Future<Map<String, Object?>> dispatch(Map<Object?, Object?> _adeleRequest0);
}

final class ScriptedModelFixtureServiceDispatcher
    implements ScriptedModelFixtureServiceRequestDispatcher {
  const ScriptedModelFixtureServiceDispatcher(this._adeleService);
  final ScriptedModelFixtureService _adeleService;
  @override
  Future<Map<String, Object?>> dispatch(
    Map<Object?, Object?> _adeleRequest0,
  ) async {
    final _adeleRequestId1 = _adeleRequest0['requestId'];
    late final String _adeleMethod2;
    try {
      _adeleMethod2 = _decodeContractEnvelope(_adeleRequest0);
    } on AdeleProtocolException catch (_adeleError3) {
      return _contractFailure(
        _adeleRequestId1,
        null,
        'invalid_request',
        _adeleError3.message,
        const {},
      );
    }
    if (!const {scriptedModelFixtureServiceInvokeId}.contains(_adeleMethod2))
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
        scriptedModelFixtureServiceInvokeId => (() {
          _contractFields(_adelePayload4, const {'request'}, 'invoke payload');
          return <Object?>[
            _decodeScriptedModelRequest(_adelePayload4['request']),
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
        scriptedModelFixtureServiceInvokeId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.invoke(
            _adeleValues0[0] as ScriptedModelRequest,
          );
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
}

String _decodeContractEnvelope(Map<Object?, Object?> _adeleRequest0) {
  _contractFields(_adeleRequest0, const {
    'kind',
    'requestId',
    'method',
    'payload',
  }, 'request envelope');
  if (_adeleRequest0['requestId'] is! int ||
      _adeleRequest0['kind'] != 'request' ||
      _adeleRequest0['method'] is! String)
    throw const AdeleProtocolException('Malformed request envelope.');
  return _adeleRequest0['method'] as String;
}

final class _ContractUnknownMethod implements Exception {
  const _ContractUnknownMethod();
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
const String scriptedModelFailureTypeId = 'scriptedModelFixture.failure';
const String scriptedModelMessageTypeId = 'scriptedModelFixture.message';
Map<String, Object?> _encodeScriptedModelMessage(
  ScriptedModelMessage _adeleValue9,
) => <String, Object?>{
  'content': _adeleValue9.content,
  'role': _adeleValue9.role.name,
  'toolCallId': switch (_adeleValue9.toolCallId) {
    final _adeleNonNullValue15? => _adeleNonNullValue15,
    null => null,
  },
  'toolOutcome': switch (_adeleValue9.toolOutcome) {
    final _adeleNonNullValue19? => _adeleNonNullValue19.name,
    null => null,
  },
  'toolProposal': switch (_adeleValue9.toolProposal) {
    final _adeleNonNullValue23? => _encodeScriptedToolCall(
      _adeleNonNullValue23,
    ),
    null => null,
  },
};
ScriptedModelMessage _decodeScriptedModelMessage(Object? _adeleValue26) {
  final _adeleMap27 = _contractMap(_adeleValue26, 'ScriptedModelMessage');
  _contractFields(_adeleMap27, const {
    'content',
    'role',
    'toolCallId',
    'toolOutcome',
    'toolProposal',
  }, 'ScriptedModelMessage');
  final _adeleField28 = _contractString(_adeleMap27['content'], 'content');
  final _adeleField29 = _decodeScriptedModelMessageRole(_adeleMap27['role']);
  final _adeleField30 = switch (_adeleMap27['toolCallId']) {
    final _adeleNonNullValue38? => _contractString(
      _adeleNonNullValue38,
      'toolCallId',
    ),
    null => null,
  };
  final _adeleField31 = switch (_adeleMap27['toolOutcome']) {
    final _adeleNonNullValue42? => _decodeScriptedToolOutcomeStatus(
      _adeleNonNullValue42,
    ),
    null => null,
  };
  final _adeleField32 = switch (_adeleMap27['toolProposal']) {
    final _adeleNonNullValue46? => _decodeScriptedToolCall(
      _adeleNonNullValue46,
    ),
    null => null,
  };
  return _contractConstruct(
    'ScriptedModelMessage',
    () => ScriptedModelMessage(
      content: _adeleField28,
      role: _adeleField29,
      toolCallId: _adeleField30,
      toolOutcome: _adeleField31,
      toolProposal: _adeleField32,
    ),
  );
}

const String scriptedModelRequestTypeId = 'scriptedModelFixture.request';
Map<String, Object?> _encodeScriptedModelRequest(
  ScriptedModelRequest _adeleValue49,
) => <String, Object?>{
  'messages': _adeleValue49.messages
      .map((_adeleElement50) => _encodeScriptedModelMessage(_adeleElement50))
      .toList(growable: false),
  'tools': _adeleValue49.tools
      .map((_adeleElement54) => _encodeScriptedToolDefinition(_adeleElement54))
      .toList(growable: false),
};
ScriptedModelRequest _decodeScriptedModelRequest(Object? _adeleValue58) {
  final _adeleMap59 = _contractMap(_adeleValue58, 'ScriptedModelRequest');
  _contractFields(_adeleMap59, const {
    'messages',
    'tools',
  }, 'ScriptedModelRequest');
  final _adeleField60 = List<ScriptedModelMessage>.unmodifiable(
    _contractList(
      _adeleMap59['messages'],
      'messages',
    ).map((_adeleElement62) => _decodeScriptedModelMessage(_adeleElement62)),
  );
  final _adeleField61 = List<ScriptedToolDefinition>.unmodifiable(
    _contractList(
      _adeleMap59['tools'],
      'tools',
    ).map((_adeleElement66) => _decodeScriptedToolDefinition(_adeleElement66)),
  );
  return _contractConstruct(
    'ScriptedModelRequest',
    () => ScriptedModelRequest(messages: _adeleField60, tools: _adeleField61),
  );
}

const String scriptedModelResponseTypeId = 'scriptedModelFixture.response';
Map<String, Object?> _encodeScriptedModelResponse(
  ScriptedModelResponse _adeleValue70,
) => <String, Object?>{
  'content': _adeleValue70.content,
  'toolCall': switch (_adeleValue70.toolCall) {
    final _adeleNonNullValue74? => _encodeScriptedToolCall(
      _adeleNonNullValue74,
    ),
    null => null,
  },
};
ScriptedModelResponse _decodeScriptedModelResponse(Object? _adeleValue77) {
  final _adeleMap78 = _contractMap(_adeleValue77, 'ScriptedModelResponse');
  _contractFields(_adeleMap78, const {
    'content',
    'toolCall',
  }, 'ScriptedModelResponse');
  final _adeleField79 = _contractString(_adeleMap78['content'], 'content');
  final _adeleField80 = switch (_adeleMap78['toolCall']) {
    final _adeleNonNullValue84? => _decodeScriptedToolCall(
      _adeleNonNullValue84,
    ),
    null => null,
  };
  return _contractConstruct(
    'ScriptedModelResponse',
    () =>
        ScriptedModelResponse(content: _adeleField79, toolCall: _adeleField80),
  );
}

const String scriptedToolCallTypeId = 'scriptedModelFixture.toolCall';
Map<String, Object?> _encodeScriptedToolCall(ScriptedToolCall _adeleValue87) =>
    <String, Object?>{
      'arguments': _contractJsonMap(_adeleValue87.arguments, 'map'),
      'id': _adeleValue87.id,
      'name': _adeleValue87.name,
    };
ScriptedToolCall _decodeScriptedToolCall(Object? _adeleValue94) {
  final _adeleMap95 = _contractMap(_adeleValue94, 'ScriptedToolCall');
  _contractFields(_adeleMap95, const {
    'arguments',
    'id',
    'name',
  }, 'ScriptedToolCall');
  final _adeleField96 = _contractJsonMap(_adeleMap95['arguments'], 'arguments');
  final _adeleField97 = _contractString(_adeleMap95['id'], 'id');
  final _adeleField98 = _contractString(_adeleMap95['name'], 'name');
  return _contractConstruct(
    'ScriptedToolCall',
    () => ScriptedToolCall(
      arguments: _adeleField96,
      id: _adeleField97,
      name: _adeleField98,
    ),
  );
}

const String scriptedToolDefinitionTypeId =
    'scriptedModelFixture.toolDefinition';
Map<String, Object?> _encodeScriptedToolDefinition(
  ScriptedToolDefinition _adeleValue105,
) => <String, Object?>{
  'argumentsSchema': _contractJsonMap(_adeleValue105.argumentsSchema, 'map'),
  'description': _adeleValue105.description,
  'name': _adeleValue105.name,
};
ScriptedToolDefinition _decodeScriptedToolDefinition(Object? _adeleValue112) {
  final _adeleMap113 = _contractMap(_adeleValue112, 'ScriptedToolDefinition');
  _contractFields(_adeleMap113, const {
    'argumentsSchema',
    'description',
    'name',
  }, 'ScriptedToolDefinition');
  final _adeleField114 = _contractJsonMap(
    _adeleMap113['argumentsSchema'],
    'argumentsSchema',
  );
  final _adeleField115 = _contractString(
    _adeleMap113['description'],
    'description',
  );
  final _adeleField116 = _contractString(_adeleMap113['name'], 'name');
  return _contractConstruct(
    'ScriptedToolDefinition',
    () => ScriptedToolDefinition(
      argumentsSchema: _adeleField114,
      description: _adeleField115,
      name: _adeleField116,
    ),
  );
}

ScriptedModelMessageRole _decodeScriptedModelMessageRole(
  Object? _adeleValue123,
) {
  if (_adeleValue123 is! String)
    throw AdeleProtocolException('Expected ScriptedModelMessageRole.');
  return switch (_adeleValue123) {
    'user' => ScriptedModelMessageRole.user,
    'assistant' => ScriptedModelMessageRole.assistant,
    'tool' => ScriptedModelMessageRole.tool,
    _ => throw AdeleProtocolException(
      'Unknown ScriptedModelMessageRole: ' + _adeleValue123 + '.',
    ),
  };
}

ScriptedToolOutcomeStatus _decodeScriptedToolOutcomeStatus(
  Object? _adeleValue124,
) {
  if (_adeleValue124 is! String)
    throw AdeleProtocolException('Expected ScriptedToolOutcomeStatus.');
  return switch (_adeleValue124) {
    'success' => ScriptedToolOutcomeStatus.success,
    'userRejected' => ScriptedToolOutcomeStatus.userRejected,
    'policyDenied' => ScriptedToolOutcomeStatus.policyDenied,
    'failure' => ScriptedToolOutcomeStatus.failure,
    'cancelled' => ScriptedToolOutcomeStatus.cancelled,
    'indeterminate' => ScriptedToolOutcomeStatus.indeterminate,
    _ => throw AdeleProtocolException(
      'Unknown ScriptedToolOutcomeStatus: ' + _adeleValue124 + '.',
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
