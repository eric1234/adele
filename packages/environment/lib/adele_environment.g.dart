// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'adele_environment.dart';

const String environmentProviderServiceId = 'environment';
const String environmentProviderServiceEstablishId = 'environment.establish';
const String environmentProviderServiceReadDirectoryId =
    'environment.readDirectory';
const String environmentProviderServiceReadFileId = 'environment.readFile';
const String environmentProviderServiceReplaceExistingTextFileId =
    'environment.replaceExistingTextFile';
const String environmentProviderServiceRestoreId = 'environment.restore';

final class EnvironmentProviderServiceClient
    implements EnvironmentProviderService {
  const EnvironmentProviderServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
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
    } on AdeleRemoteFailure catch (_adeleError5) {
      switch (_adeleError5.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError5.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
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
    } on AdeleRemoteFailure catch (_adeleError12) {
      switch (_adeleError12.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError12.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError12.code,
              message: _adeleError12.message,
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
    } on AdeleRemoteFailure catch (_adeleError19) {
      switch (_adeleError19.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError19.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError19.code,
              message: _adeleError19.message,
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
    } on AdeleRemoteFailure catch (_adeleError30) {
      switch (_adeleError30.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError30.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError30.code,
              message: _adeleError30.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class EnvironmentProviderServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class EnvironmentProviderServiceDispatcher
    implements EnvironmentProviderServiceRequestDispatcher {
  EnvironmentProviderServiceDispatcher(this._adeleService);
  final EnvironmentProviderService _adeleService;
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
      environmentProviderServiceEstablishId,
      environmentProviderServiceReadDirectoryId,
      environmentProviderServiceReadFileId,
      environmentProviderServiceReplaceExistingTextFileId,
      environmentProviderServiceRestoreId,
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
const String environmentFailureTypeId = 'environment.failure';
const String environmentTransportContextTypeId = 'environment.context';
Map<String, Object?> _encodeEnvironmentTransportContext(
  EnvironmentTransportContext _adeleValue65,
) => <String, Object?>{
  'environmentId': _adeleValue65.environmentId,
  'environmentRole': _adeleValue65.environmentRole,
  'projectId': _adeleValue65.projectId,
  'projectSourceLocation': _contractUriString(
    _adeleValue65.projectSourceLocation,
    'Uri',
  ),
  'providerId': _adeleValue65.providerId,
  'providerState': _contractJsonMap(_adeleValue65.providerState, 'map'),
  'providerStateInitialized': _adeleValue65.providerStateInitialized,
  'taskId': _adeleValue65.taskId,
  'taskTitle': _adeleValue65.taskTitle,
};
EnvironmentTransportContext _decodeEnvironmentTransportContext(
  Object? _adeleValue84,
) {
  final _adeleMap85 = _contractMap(
    _adeleValue84,
    'EnvironmentTransportContext',
  );
  _contractFields(_adeleMap85, const {
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
  final _adeleField86 = _contractString(
    _adeleMap85['environmentId'],
    'environmentId',
  );
  final _adeleField87 = _contractString(
    _adeleMap85['environmentRole'],
    'environmentRole',
  );
  final _adeleField88 = _contractString(_adeleMap85['projectId'], 'projectId');
  final _adeleField89 = _contractUri(
    _adeleMap85['projectSourceLocation'],
    'projectSourceLocation',
  );
  final _adeleField90 = _contractString(
    _adeleMap85['providerId'],
    'providerId',
  );
  final _adeleField91 = _contractJsonMap(
    _adeleMap85['providerState'],
    'providerState',
  );
  final _adeleField92 = _contractBool(
    _adeleMap85['providerStateInitialized'],
    'providerStateInitialized',
  );
  final _adeleField93 = _contractString(_adeleMap85['taskId'], 'taskId');
  final _adeleField94 = _contractString(_adeleMap85['taskTitle'], 'taskTitle');
  return _contractConstruct(
    'EnvironmentTransportContext',
    () => EnvironmentTransportContext(
      environmentId: _adeleField86,
      environmentRole: _adeleField87,
      projectId: _adeleField88,
      projectSourceLocation: _adeleField89,
      providerId: _adeleField90,
      providerState: _adeleField91,
      providerStateInitialized: _adeleField92,
      taskId: _adeleField93,
      taskTitle: _adeleField94,
    ),
  );
}

const String environmentDirectoryEntryTypeId = 'environment.directoryEntry';
Map<String, Object?> _encodeEnvironmentDirectoryEntry(
  EnvironmentDirectoryEntry _adeleValue113,
) => <String, Object?>{
  'kind': _adeleValue113.kind.name,
  'name': _adeleValue113.name,
  'relativePath': _adeleValue113.relativePath,
};
EnvironmentDirectoryEntry _decodeEnvironmentDirectoryEntry(
  Object? _adeleValue120,
) {
  final _adeleMap121 = _contractMap(
    _adeleValue120,
    'EnvironmentDirectoryEntry',
  );
  _contractFields(_adeleMap121, const {
    'kind',
    'name',
    'relativePath',
  }, 'EnvironmentDirectoryEntry');
  final _adeleField122 = _decodeEnvironmentDirectoryEntryKind(
    _adeleMap121['kind'],
  );
  final _adeleField123 = _contractString(_adeleMap121['name'], 'name');
  final _adeleField124 = _contractString(
    _adeleMap121['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryEntry',
    () => EnvironmentDirectoryEntry(
      kind: _adeleField122,
      name: _adeleField123,
      relativePath: _adeleField124,
    ),
  );
}

const String environmentDirectoryListingTypeId = 'environment.directoryListing';
Map<String, Object?> _encodeEnvironmentDirectoryListing(
  EnvironmentDirectoryListing _adeleValue131,
) => <String, Object?>{
  'entries': _adeleValue131.entries
      .map(
        (_adeleElement132) =>
            _encodeEnvironmentDirectoryEntry(_adeleElement132),
      )
      .toList(growable: false),
  'relativePath': _adeleValue131.relativePath,
};
EnvironmentDirectoryListing _decodeEnvironmentDirectoryListing(
  Object? _adeleValue138,
) {
  final _adeleMap139 = _contractMap(
    _adeleValue138,
    'EnvironmentDirectoryListing',
  );
  _contractFields(_adeleMap139, const {
    'entries',
    'relativePath',
  }, 'EnvironmentDirectoryListing');
  final _adeleField140 = List<EnvironmentDirectoryEntry>.unmodifiable(
    _contractList(_adeleMap139['entries'], 'entries').map(
      (_adeleElement142) => _decodeEnvironmentDirectoryEntry(_adeleElement142),
    ),
  );
  final _adeleField141 = _contractString(
    _adeleMap139['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryListing',
    () => EnvironmentDirectoryListing(
      entries: _adeleField140,
      relativePath: _adeleField141,
    ),
  );
}

const String environmentProviderResultTypeId = 'environment.providerResult';
Map<String, Object?> _encodeEnvironmentProviderResult(
  EnvironmentProviderResult _adeleValue148,
) => <String, Object?>{
  'providerState': _contractJsonMap(_adeleValue148.providerState, 'map'),
};
EnvironmentProviderResult _decodeEnvironmentProviderResult(
  Object? _adeleValue151,
) {
  final _adeleMap152 = _contractMap(
    _adeleValue151,
    'EnvironmentProviderResult',
  );
  _contractFields(_adeleMap152, const {
    'providerState',
  }, 'EnvironmentProviderResult');
  final _adeleField153 = _contractJsonMap(
    _adeleMap152['providerState'],
    'providerState',
  );
  return _contractConstruct(
    'EnvironmentProviderResult',
    () => EnvironmentProviderResult(providerState: _adeleField153),
  );
}

const String environmentTextFileTypeId = 'environment.textFile';
Map<String, Object?> _encodeEnvironmentTextFile(
  EnvironmentTextFile _adeleValue156,
) => <String, Object?>{
  'relativePath': _adeleValue156.relativePath,
  'revision': _adeleValue156.revision,
  'sizeBytes': _adeleValue156.sizeBytes,
  'text': _adeleValue156.text,
};
EnvironmentTextFile _decodeEnvironmentTextFile(Object? _adeleValue165) {
  final _adeleMap166 = _contractMap(_adeleValue165, 'EnvironmentTextFile');
  _contractFields(_adeleMap166, const {
    'relativePath',
    'revision',
    'sizeBytes',
    'text',
  }, 'EnvironmentTextFile');
  final _adeleField167 = _contractString(
    _adeleMap166['relativePath'],
    'relativePath',
  );
  final _adeleField168 = _contractString(_adeleMap166['revision'], 'revision');
  final _adeleField169 = _contractInt(_adeleMap166['sizeBytes'], 'sizeBytes');
  final _adeleField170 = _contractString(_adeleMap166['text'], 'text');
  return _contractConstruct(
    'EnvironmentTextFile',
    () => EnvironmentTextFile(
      relativePath: _adeleField167,
      revision: _adeleField168,
      sizeBytes: _adeleField169,
      text: _adeleField170,
    ),
  );
}

const String environmentTextFileReplacementTypeId =
    'environment.textFileReplacement';
Map<String, Object?> _encodeEnvironmentTextFileReplacement(
  EnvironmentTextFileReplacement _adeleValue179,
) => <String, Object?>{'revision': _adeleValue179.revision};
EnvironmentTextFileReplacement _decodeEnvironmentTextFileReplacement(
  Object? _adeleValue182,
) {
  final _adeleMap183 = _contractMap(
    _adeleValue182,
    'EnvironmentTextFileReplacement',
  );
  _contractFields(_adeleMap183, const {
    'revision',
  }, 'EnvironmentTextFileReplacement');
  final _adeleField184 = _contractString(_adeleMap183['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileReplacement',
    () => EnvironmentTextFileReplacement(revision: _adeleField184),
  );
}

EnvironmentDirectoryEntryKind _decodeEnvironmentDirectoryEntryKind(
  Object? _adeleValue187,
) {
  if (_adeleValue187 is! String)
    throw AdeleProtocolException('Expected EnvironmentDirectoryEntryKind.');
  return switch (_adeleValue187) {
    'file' => EnvironmentDirectoryEntryKind.file,
    'directory' => EnvironmentDirectoryEntryKind.directory,
    'other' => EnvironmentDirectoryEntryKind.other,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentDirectoryEntryKind: ' + _adeleValue187 + '.',
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
