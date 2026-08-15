// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'workspace_demo_contract.dart';

const String workspaceDemoServiceId = 'workspaceDemo';
const String workspaceDemoServiceListDirectoryId =
    'workspaceDemo.listDirectory';
const String workspaceDemoServiceReadTextFileId = 'workspaceDemo.readTextFile';

final class WorkspaceDemoServiceClient implements WorkspaceDemoService {
  const WorkspaceDemoServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<DirectoryListing> listDirectory(ResourceRef directory) async {
    try {
      return _decodeDirectoryListing(
        await this._adeleChannel.request(
          workspaceDemoServiceListDirectoryId,
          <String, Object?>{'directory': _contractResourceRef(directory)},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError0) {
      switch (_adeleError0.declaredFailureType) {
        case workspaceDemoFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError0.details,
            'failure details',
          );
          throw _contractConstruct(
            'WorkspaceDemoFailure',
            () => WorkspaceDemoFailure(
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
  Future<TextFileContents> readTextFile(ResourceRef file) async {
    try {
      return _decodeTextFileContents(
        await this._adeleChannel.request(
          workspaceDemoServiceReadTextFileId,
          <String, Object?>{'file': _contractResourceRef(file)},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError5) {
      switch (_adeleError5.declaredFailureType) {
        case workspaceDemoFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError5.details,
            'failure details',
          );
          throw _contractConstruct(
            'WorkspaceDemoFailure',
            () => WorkspaceDemoFailure(
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

abstract interface class WorkspaceDemoServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class WorkspaceDemoServiceDispatcher
    implements WorkspaceDemoServiceRequestDispatcher {
  WorkspaceDemoServiceDispatcher(this._adeleService);
  final WorkspaceDemoService _adeleService;
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
      workspaceDemoServiceListDirectoryId,
      workspaceDemoServiceReadTextFileId,
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
        workspaceDemoServiceListDirectoryId => (() {
          _contractFields(_adelePayload4, const {
            'directory',
          }, 'listDirectory payload');
          return <Object?>[_decodeResourceRef(_adelePayload4['directory'])];
        })(),
        workspaceDemoServiceReadTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'file',
          }, 'readTextFile payload');
          return <Object?>[_decodeResourceRef(_adelePayload4['file'])];
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
        workspaceDemoServiceListDirectoryId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.listDirectory(
            _adeleValues0[0] as ResourceRef,
          );
        })(),
        workspaceDemoServiceReadTextFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.readTextFile(
            _adeleValues0[0] as ResourceRef,
          );
        })(),
        _ => throw const _ContractUnknownMethod(),
      };
    } on WorkspaceDemoFailure catch (_adeleError9) {
      try {
        return _contractFailure(
          _adeleRequestId1,
          workspaceDemoFailureTypeId,
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
        workspaceDemoServiceListDirectoryId => _encodeDirectoryListing(
          (_adeleResult8 as DirectoryListing),
        ),
        workspaceDemoServiceReadTextFileId => _encodeTextFileContents(
          (_adeleResult8 as TextFileContents),
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
const String workspaceDemoFailureTypeId = 'workspaceDemo.failure';
const String directoryEntryTypeId = 'workspaceDemo.directoryEntry';
Map<String, Object?> _encodeDirectoryEntry(DirectoryEntry _adeleValue18) =>
    <String, Object?>{
      'kind': _adeleValue18.kind.name,
      'name': _adeleValue18.name,
      'resource': _contractResourceRef(_adeleValue18.resource),
    };
DirectoryEntry _decodeDirectoryEntry(Object? _adeleValue25) {
  final _adeleMap26 = _contractMap(_adeleValue25, 'DirectoryEntry');
  _contractFields(_adeleMap26, const {
    'kind',
    'name',
    'resource',
  }, 'DirectoryEntry');
  final _adeleField27 = _decodeDirectoryEntryKind(_adeleMap26['kind']);
  final _adeleField28 = _contractString(_adeleMap26['name'], 'name');
  final _adeleField29 = _decodeResourceRef(_adeleMap26['resource']);
  return _contractConstruct(
    'DirectoryEntry',
    () => DirectoryEntry(
      kind: _adeleField27,
      name: _adeleField28,
      resource: _adeleField29,
    ),
  );
}

const String directoryListingTypeId = 'workspaceDemo.directoryListing';
Map<String, Object?> _encodeDirectoryListing(DirectoryListing _adeleValue36) =>
    <String, Object?>{
      'directory': _contractResourceRef(_adeleValue36.directory),
      'entries': _adeleValue36.entries
          .map((_adeleElement39) => _encodeDirectoryEntry(_adeleElement39))
          .toList(growable: false),
    };
DirectoryListing _decodeDirectoryListing(Object? _adeleValue43) {
  final _adeleMap44 = _contractMap(_adeleValue43, 'DirectoryListing');
  _contractFields(_adeleMap44, const {
    'directory',
    'entries',
  }, 'DirectoryListing');
  final _adeleField45 = _decodeResourceRef(_adeleMap44['directory']);
  final _adeleField46 = List<DirectoryEntry>.unmodifiable(
    _contractList(
      _adeleMap44['entries'],
      'entries',
    ).map((_adeleElement49) => _decodeDirectoryEntry(_adeleElement49)),
  );
  return _contractConstruct(
    'DirectoryListing',
    () => DirectoryListing(directory: _adeleField45, entries: _adeleField46),
  );
}

const String textFileContentsTypeId = 'workspaceDemo.textFileContents';
Map<String, Object?> _encodeTextFileContents(TextFileContents _adeleValue53) =>
    <String, Object?>{
      'resource': _contractResourceRef(_adeleValue53.resource),
      'text': _adeleValue53.text,
    };
TextFileContents _decodeTextFileContents(Object? _adeleValue58) {
  final _adeleMap59 = _contractMap(_adeleValue58, 'TextFileContents');
  _contractFields(_adeleMap59, const {'resource', 'text'}, 'TextFileContents');
  final _adeleField60 = _decodeResourceRef(_adeleMap59['resource']);
  final _adeleField61 = _contractString(_adeleMap59['text'], 'text');
  return _contractConstruct(
    'TextFileContents',
    () => TextFileContents(resource: _adeleField60, text: _adeleField61),
  );
}

DirectoryEntryKind _decodeDirectoryEntryKind(Object? _adeleValue66) {
  if (_adeleValue66 is! String)
    throw AdeleProtocolException('Expected DirectoryEntryKind.');
  return switch (_adeleValue66) {
    'directory' => DirectoryEntryKind.directory,
    'file' => DirectoryEntryKind.file,
    _ => throw AdeleProtocolException(
      'Unknown DirectoryEntryKind: ' + _adeleValue66 + '.',
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

Map<String, Object?> _contractResourceRef(ResourceRef _adeleValue0) => {
  'uri': _contractUriString(_adeleValue0.uri, 'ResourceRef uri'),
  'mediaType': _adeleValue0.mediaType,
};
ResourceRef _decodeResourceRef(Object? _adeleValue0) {
  final _adeleMap1 = _contractMap(_adeleValue0, 'ResourceRef');
  _contractFields(_adeleMap1, const {'uri', 'mediaType'}, 'ResourceRef');
  final _adeleUri2 = _contractUri(_adeleMap1['uri'], 'ResourceRef uri');
  final _adeleMediaType3 = _adeleMap1['mediaType'];
  if (_adeleMediaType3 != null && _adeleMediaType3 is! String)
    throw const AdeleProtocolException('Malformed ResourceRef.');
  return _contractConstruct(
    'ResourceRef',
    () => ResourceRef(uri: _adeleUri2, mediaType: _adeleMediaType3 as String?),
  );
}
