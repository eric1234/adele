// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'development_source_contract.dart';

const String developmentSourceServiceId = 'developmentSource';
const String developmentSourceServiceReadTextFileId =
    'developmentSource.readTextFile';
const String developmentSourceServiceSearchTextId =
    'developmentSource.searchText';

final class DevelopmentSourceServiceClient implements DevelopmentSourceService {
  const DevelopmentSourceServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<DevelopmentSourceTextFile> readTextFile(String relativePath) async {
    try {
      return _decodeDevelopmentSourceTextFile(
        await this._adeleChannel.request(
          developmentSourceServiceReadTextFileId,
          <String, Object?>{'relativePath': relativePath},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError0) {
      switch (_adeleError0.declaredFailureType) {
        case developmentSourceFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError0.details,
            'failure details',
          );
          throw _contractConstruct(
            'DevelopmentSourceFailure',
            () => DevelopmentSourceFailure(
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
  Future<DevelopmentSourceSearchResult> searchText(String literalText) async {
    try {
      return _decodeDevelopmentSourceSearchResult(
        await this._adeleChannel.request(
          developmentSourceServiceSearchTextId,
          <String, Object?>{'literalText': literalText},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError5) {
      switch (_adeleError5.declaredFailureType) {
        case developmentSourceFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError5.details,
            'failure details',
          );
          throw _contractConstruct(
            'DevelopmentSourceFailure',
            () => DevelopmentSourceFailure(
              code: _adeleError5.code,
              message: _adeleError5.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class DevelopmentSourceServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class DevelopmentSourceServiceDispatcher
    implements DevelopmentSourceServiceRequestDispatcher {
  DevelopmentSourceServiceDispatcher(this._adeleService);
  final DevelopmentSourceService _adeleService;
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
      developmentSourceServiceReadTextFileId,
      developmentSourceServiceSearchTextId,
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
        developmentSourceServiceReadTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
          }, 'readTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
          ];
        })(),
        developmentSourceServiceSearchTextId => (() {
          _contractFields(_adelePayload4, const {
            'literalText',
          }, 'searchText payload');
          return <Object?>[
            _contractString(_adelePayload4['literalText'], 'literalText'),
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
        developmentSourceServiceReadTextFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.readTextFile(
            _adeleValues0[0] as String,
          );
        })(),
        developmentSourceServiceSearchTextId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.searchText(
            _adeleValues0[0] as String,
          );
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on DevelopmentSourceFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          developmentSourceFailureTypeId,
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
        developmentSourceServiceReadTextFileId =>
          _encodeDevelopmentSourceTextFile(
            (_adeleResult8 as DevelopmentSourceTextFile),
          ),
        developmentSourceServiceSearchTextId =>
          _encodeDevelopmentSourceSearchResult(
            (_adeleResult8 as DevelopmentSourceSearchResult),
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
const String developmentSourceFailureTypeId = 'developmentSource.failure';
const String developmentSourceSearchMatchTypeId =
    'developmentSource.searchMatch';
Map<String, Object?> _encodeDevelopmentSourceSearchMatch(
  DevelopmentSourceSearchMatch _adeleValue18,
) => <String, Object?>{
  'lineNumber': _adeleValue18.lineNumber,
  'relativePath': _adeleValue18.relativePath,
  'snippet': _adeleValue18.snippet,
};
DevelopmentSourceSearchMatch _decodeDevelopmentSourceSearchMatch(
  Object? _adeleValue25,
) {
  final _adeleMap26 = _contractMap(
    _adeleValue25,
    'DevelopmentSourceSearchMatch',
  );
  _contractFields(_adeleMap26, const {
    'lineNumber',
    'relativePath',
    'snippet',
  }, 'DevelopmentSourceSearchMatch');
  final _adeleField27 = _contractInt(_adeleMap26['lineNumber'], 'lineNumber');
  final _adeleField28 = _contractString(
    _adeleMap26['relativePath'],
    'relativePath',
  );
  final _adeleField29 = _contractString(_adeleMap26['snippet'], 'snippet');
  return _contractConstruct(
    'DevelopmentSourceSearchMatch',
    () => DevelopmentSourceSearchMatch(
      lineNumber: _adeleField27,
      relativePath: _adeleField28,
      snippet: _adeleField29,
    ),
  );
}

const String developmentSourceSearchResultTypeId =
    'developmentSource.searchResult';
Map<String, Object?> _encodeDevelopmentSourceSearchResult(
  DevelopmentSourceSearchResult _adeleValue36,
) => <String, Object?>{
  'matches': _adeleValue36.matches
      .map(
        (_adeleElement37) =>
            _encodeDevelopmentSourceSearchMatch(_adeleElement37),
      )
      .toList(growable: false),
  'truncated': _adeleValue36.truncated,
};
DevelopmentSourceSearchResult _decodeDevelopmentSourceSearchResult(
  Object? _adeleValue43,
) {
  final _adeleMap44 = _contractMap(
    _adeleValue43,
    'DevelopmentSourceSearchResult',
  );
  _contractFields(_adeleMap44, const {
    'matches',
    'truncated',
  }, 'DevelopmentSourceSearchResult');
  final _adeleField45 = List<DevelopmentSourceSearchMatch>.unmodifiable(
    _contractList(_adeleMap44['matches'], 'matches').map(
      (_adeleElement47) => _decodeDevelopmentSourceSearchMatch(_adeleElement47),
    ),
  );
  final _adeleField46 = _contractBool(_adeleMap44['truncated'], 'truncated');
  return _contractConstruct(
    'DevelopmentSourceSearchResult',
    () => DevelopmentSourceSearchResult(
      matches: _adeleField45,
      truncated: _adeleField46,
    ),
  );
}

const String developmentSourceTextFileTypeId = 'developmentSource.textFile';
Map<String, Object?> _encodeDevelopmentSourceTextFile(
  DevelopmentSourceTextFile _adeleValue53,
) => <String, Object?>{
  'relativePath': _adeleValue53.relativePath,
  'sizeBytes': _adeleValue53.sizeBytes,
  'text': _adeleValue53.text,
};
DevelopmentSourceTextFile _decodeDevelopmentSourceTextFile(
  Object? _adeleValue60,
) {
  final _adeleMap61 = _contractMap(_adeleValue60, 'DevelopmentSourceTextFile');
  _contractFields(_adeleMap61, const {
    'relativePath',
    'sizeBytes',
    'text',
  }, 'DevelopmentSourceTextFile');
  final _adeleField62 = _contractString(
    _adeleMap61['relativePath'],
    'relativePath',
  );
  final _adeleField63 = _contractInt(_adeleMap61['sizeBytes'], 'sizeBytes');
  final _adeleField64 = _contractString(_adeleMap61['text'], 'text');
  return _contractConstruct(
    'DevelopmentSourceTextFile',
    () => DevelopmentSourceTextFile(
      relativePath: _adeleField62,
      sizeBytes: _adeleField63,
      text: _adeleField64,
    ),
  );
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
