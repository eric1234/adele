// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'adele_environment.dart';

const String authorizedEnvironmentReadServiceId = 'authorizedEnvironmentRead';
const String authorizedEnvironmentReadServiceReadFileId =
    'authorizedEnvironmentRead.readFile';

final class AuthorizedEnvironmentReadServiceClient
    implements AuthorizedEnvironmentReadService {
  const AuthorizedEnvironmentReadServiceClient(
    AdeleRequestChannel _adeleChannel,
  ) : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    try {
      return _decodeEnvironmentTextFile(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceReadFileId,
          <String, Object?>{'relativePath': relativePath},
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
    } on AdeleRemoteFailure catch (_adeleError9) {
      switch (_adeleError9.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError9.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError9.code,
              message: _adeleError9.message,
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
      final _adeleResponse25 = await this._adeleChannel.request(
        environmentProviderServiceDeleteExistingTextFileId,
        <String, Object?>{
          'environmentId': environmentId,
          'relativePath': relativePath,
          'expectedRevision': expectedRevision,
        },
      );
      _contractVoid(_adeleResponse25, 'deleteExistingTextFile');
      return;
    } on AdeleRemoteFailure catch (_adeleError18) {
      switch (_adeleError18.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError18.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError18.code,
              message: _adeleError18.message,
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
    } on AdeleRemoteFailure catch (_adeleError26) {
      switch (_adeleError26.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError26.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError26.code,
              message: _adeleError26.message,
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
    } on AdeleRemoteFailure catch (_adeleError31) {
      switch (_adeleError31.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError31.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError31.code,
              message: _adeleError31.message,
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
    } on AdeleRemoteFailure catch (_adeleError38) {
      switch (_adeleError38.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError38.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError38.code,
              message: _adeleError38.message,
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
    } on AdeleRemoteFailure catch (_adeleError45) {
      switch (_adeleError45.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError45.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError45.code,
              message: _adeleError45.message,
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
    } on AdeleRemoteFailure catch (_adeleError56) {
      switch (_adeleError56.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError56.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError56.code,
              message: _adeleError56.message,
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
    final _adeleRaw62 = _adeleStreamChannel4.stream(
      environmentProviderServiceRunForegroundProcessId,
      <String, Object?>{
        'environmentId': environmentId,
        'request': _encodeEnvironmentForegroundProcessRequest(request),
      },
    );
    return adeleDecodedStream<EnvironmentProcessEvent>(
      _adeleRaw62,
      (Object? _adeleItem5) => _decodeEnvironmentProcessEvent(_adeleItem5),
      (Object _adeleError61) {
        if (_adeleError61 is AdeleRemoteFailure) {
          switch (_adeleError61.declaredFailureType) {
            case environmentFailureTypeId:
              final _adeleDetails8 = _contractJsonMap(
                _adeleError61.details,
                'failure details',
              );
              throw _contractConstruct(
                'EnvironmentFailure',
                () => EnvironmentFailure(
                  code: _adeleError61.code,
                  message: _adeleError61.message,
                  details: _adeleDetails8,
                ),
              );
            default:
              break;
          }
        }
        return _adeleError61;
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
const String environmentTransportContextTypeId = 'environment.context';
Map<String, Object?> _encodeEnvironmentTransportContext(
  EnvironmentTransportContext _adeleValue121,
) => <String, Object?>{
  'environmentId': _adeleValue121.environmentId,
  'environmentRole': _adeleValue121.environmentRole,
  'projectId': _adeleValue121.projectId,
  'projectSourceLocation': _contractUriString(
    _adeleValue121.projectSourceLocation,
    'Uri',
  ),
  'providerId': _adeleValue121.providerId,
  'providerState': _contractJsonMap(_adeleValue121.providerState, 'map'),
  'providerStateInitialized': _adeleValue121.providerStateInitialized,
  'taskId': _adeleValue121.taskId,
  'taskTitle': _adeleValue121.taskTitle,
};
EnvironmentTransportContext _decodeEnvironmentTransportContext(
  Object? _adeleValue140,
) {
  final _adeleMap141 = _contractMap(
    _adeleValue140,
    'EnvironmentTransportContext',
  );
  _contractFields(_adeleMap141, const {
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
  final _adeleField142 = _contractString(
    _adeleMap141['environmentId'],
    'environmentId',
  );
  final _adeleField143 = _contractString(
    _adeleMap141['environmentRole'],
    'environmentRole',
  );
  final _adeleField144 = _contractString(
    _adeleMap141['projectId'],
    'projectId',
  );
  final _adeleField145 = _contractUri(
    _adeleMap141['projectSourceLocation'],
    'projectSourceLocation',
  );
  final _adeleField146 = _contractString(
    _adeleMap141['providerId'],
    'providerId',
  );
  final _adeleField147 = _contractJsonMap(
    _adeleMap141['providerState'],
    'providerState',
  );
  final _adeleField148 = _contractBool(
    _adeleMap141['providerStateInitialized'],
    'providerStateInitialized',
  );
  final _adeleField149 = _contractString(_adeleMap141['taskId'], 'taskId');
  final _adeleField150 = _contractString(
    _adeleMap141['taskTitle'],
    'taskTitle',
  );
  return _contractConstruct(
    'EnvironmentTransportContext',
    () => EnvironmentTransportContext(
      environmentId: _adeleField142,
      environmentRole: _adeleField143,
      projectId: _adeleField144,
      projectSourceLocation: _adeleField145,
      providerId: _adeleField146,
      providerState: _adeleField147,
      providerStateInitialized: _adeleField148,
      taskId: _adeleField149,
      taskTitle: _adeleField150,
    ),
  );
}

const String environmentDirectoryEntryTypeId = 'environment.directoryEntry';
Map<String, Object?> _encodeEnvironmentDirectoryEntry(
  EnvironmentDirectoryEntry _adeleValue169,
) => <String, Object?>{
  'kind': _adeleValue169.kind.name,
  'name': _adeleValue169.name,
  'relativePath': _adeleValue169.relativePath,
};
EnvironmentDirectoryEntry _decodeEnvironmentDirectoryEntry(
  Object? _adeleValue176,
) {
  final _adeleMap177 = _contractMap(
    _adeleValue176,
    'EnvironmentDirectoryEntry',
  );
  _contractFields(_adeleMap177, const {
    'kind',
    'name',
    'relativePath',
  }, 'EnvironmentDirectoryEntry');
  final _adeleField178 = _decodeEnvironmentDirectoryEntryKind(
    _adeleMap177['kind'],
  );
  final _adeleField179 = _contractString(_adeleMap177['name'], 'name');
  final _adeleField180 = _contractString(
    _adeleMap177['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryEntry',
    () => EnvironmentDirectoryEntry(
      kind: _adeleField178,
      name: _adeleField179,
      relativePath: _adeleField180,
    ),
  );
}

const String environmentDirectoryListingTypeId = 'environment.directoryListing';
Map<String, Object?> _encodeEnvironmentDirectoryListing(
  EnvironmentDirectoryListing _adeleValue187,
) => <String, Object?>{
  'entries': _adeleValue187.entries
      .map(
        (_adeleElement188) =>
            _encodeEnvironmentDirectoryEntry(_adeleElement188),
      )
      .toList(growable: false),
  'relativePath': _adeleValue187.relativePath,
};
EnvironmentDirectoryListing _decodeEnvironmentDirectoryListing(
  Object? _adeleValue194,
) {
  final _adeleMap195 = _contractMap(
    _adeleValue194,
    'EnvironmentDirectoryListing',
  );
  _contractFields(_adeleMap195, const {
    'entries',
    'relativePath',
  }, 'EnvironmentDirectoryListing');
  final _adeleField196 = List<EnvironmentDirectoryEntry>.unmodifiable(
    _contractList(_adeleMap195['entries'], 'entries').map(
      (_adeleElement198) => _decodeEnvironmentDirectoryEntry(_adeleElement198),
    ),
  );
  final _adeleField197 = _contractString(
    _adeleMap195['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryListing',
    () => EnvironmentDirectoryListing(
      entries: _adeleField196,
      relativePath: _adeleField197,
    ),
  );
}

const String environmentForegroundProcessRequestTypeId =
    'environment.foregroundProcessRequest';
Map<String, Object?> _encodeEnvironmentForegroundProcessRequest(
  EnvironmentForegroundProcessRequest _adeleValue204,
) => <String, Object?>{
  'arguments': _adeleValue204.arguments
      .map((_adeleElement205) => _adeleElement205)
      .toList(growable: false),
  'program': _adeleValue204.program,
  'relativeWorkingDirectory': _adeleValue204.relativeWorkingDirectory,
  'timeoutSeconds': _adeleValue204.timeoutSeconds,
};
EnvironmentForegroundProcessRequest _decodeEnvironmentForegroundProcessRequest(
  Object? _adeleValue215,
) {
  final _adeleMap216 = _contractMap(
    _adeleValue215,
    'EnvironmentForegroundProcessRequest',
  );
  _contractFields(_adeleMap216, const {
    'arguments',
    'program',
    'relativeWorkingDirectory',
    'timeoutSeconds',
  }, 'EnvironmentForegroundProcessRequest');
  final _adeleField217 = List<String>.unmodifiable(
    _contractList(_adeleMap216['arguments'], 'arguments').map(
      (_adeleElement221) =>
          _contractString(_adeleElement221, 'arguments element'),
    ),
  );
  final _adeleField218 = _contractString(_adeleMap216['program'], 'program');
  final _adeleField219 = _contractString(
    _adeleMap216['relativeWorkingDirectory'],
    'relativeWorkingDirectory',
  );
  final _adeleField220 = _contractInt(
    _adeleMap216['timeoutSeconds'],
    'timeoutSeconds',
  );
  return _contractConstruct(
    'EnvironmentForegroundProcessRequest',
    () => EnvironmentForegroundProcessRequest(
      arguments: _adeleField217,
      program: _adeleField218,
      relativeWorkingDirectory: _adeleField219,
      timeoutSeconds: _adeleField220,
    ),
  );
}

const String environmentProcessCompletedTypeId = 'environment.processCompleted';
Map<String, Object?> _encodeEnvironmentProcessCompleted(
  EnvironmentProcessCompleted _adeleValue231,
) => <String, Object?>{
  'exitCode': switch (_adeleValue231.exitCode) {
    final _adeleNonNullValue233? => _adeleNonNullValue233,
    null => null,
  },
  'stderrTruncated': _adeleValue231.stderrTruncated,
  'stdoutTruncated': _adeleValue231.stdoutTruncated,
  'termination': _adeleValue231.termination.name,
};
EnvironmentProcessCompleted _decodeEnvironmentProcessCompleted(
  Object? _adeleValue242,
) {
  final _adeleMap243 = _contractMap(
    _adeleValue242,
    'EnvironmentProcessCompleted',
  );
  _contractFields(_adeleMap243, const {
    'exitCode',
    'stderrTruncated',
    'stdoutTruncated',
    'termination',
  }, 'EnvironmentProcessCompleted');
  final _adeleField244 = switch (_adeleMap243['exitCode']) {
    final _adeleNonNullValue249? => _contractInt(
      _adeleNonNullValue249,
      'exitCode',
    ),
    null => null,
  };
  final _adeleField245 = _contractBool(
    _adeleMap243['stderrTruncated'],
    'stderrTruncated',
  );
  final _adeleField246 = _contractBool(
    _adeleMap243['stdoutTruncated'],
    'stdoutTruncated',
  );
  final _adeleField247 = _decodeEnvironmentProcessTermination(
    _adeleMap243['termination'],
  );
  return _contractConstruct(
    'EnvironmentProcessCompleted',
    () => EnvironmentProcessCompleted(
      exitCode: _adeleField244,
      stderrTruncated: _adeleField245,
      stdoutTruncated: _adeleField246,
      termination: _adeleField247,
    ),
  );
}

const String environmentProcessEventTypeId = 'environment.processEvent';
Map<String, Object?> _encodeEnvironmentProcessEvent(
  EnvironmentProcessEvent _adeleValue258,
) => <String, Object?>{
  'completed': switch (_adeleValue258.completed) {
    final _adeleNonNullValue260? => _encodeEnvironmentProcessCompleted(
      _adeleNonNullValue260,
    ),
    null => null,
  },
  'kind': _adeleValue258.kind.name,
  'output': switch (_adeleValue258.output) {
    final _adeleNonNullValue266? => _encodeEnvironmentProcessOutput(
      _adeleNonNullValue266,
    ),
    null => null,
  },
};
EnvironmentProcessEvent _decodeEnvironmentProcessEvent(Object? _adeleValue269) {
  final _adeleMap270 = _contractMap(_adeleValue269, 'EnvironmentProcessEvent');
  _contractFields(_adeleMap270, const {
    'completed',
    'kind',
    'output',
  }, 'EnvironmentProcessEvent');
  final _adeleField271 = switch (_adeleMap270['completed']) {
    final _adeleNonNullValue275? => _decodeEnvironmentProcessCompleted(
      _adeleNonNullValue275,
    ),
    null => null,
  };
  final _adeleField272 = _decodeEnvironmentProcessEventKind(
    _adeleMap270['kind'],
  );
  final _adeleField273 = switch (_adeleMap270['output']) {
    final _adeleNonNullValue281? => _decodeEnvironmentProcessOutput(
      _adeleNonNullValue281,
    ),
    null => null,
  };
  return _contractConstruct(
    'EnvironmentProcessEvent',
    () => EnvironmentProcessEvent(
      completed: _adeleField271,
      kind: _adeleField272,
      output: _adeleField273,
    ),
  );
}

const String environmentProcessOutputTypeId = 'environment.processOutput';
Map<String, Object?> _encodeEnvironmentProcessOutput(
  EnvironmentProcessOutput _adeleValue284,
) => <String, Object?>{
  'stream': _adeleValue284.stream.name,
  'text': _adeleValue284.text,
};
EnvironmentProcessOutput _decodeEnvironmentProcessOutput(
  Object? _adeleValue289,
) {
  final _adeleMap290 = _contractMap(_adeleValue289, 'EnvironmentProcessOutput');
  _contractFields(_adeleMap290, const {
    'stream',
    'text',
  }, 'EnvironmentProcessOutput');
  final _adeleField291 = _decodeEnvironmentProcessOutputStream(
    _adeleMap290['stream'],
  );
  final _adeleField292 = _contractString(_adeleMap290['text'], 'text');
  return _contractConstruct(
    'EnvironmentProcessOutput',
    () =>
        EnvironmentProcessOutput(stream: _adeleField291, text: _adeleField292),
  );
}

const String environmentProviderResultTypeId = 'environment.providerResult';
Map<String, Object?> _encodeEnvironmentProviderResult(
  EnvironmentProviderResult _adeleValue297,
) => <String, Object?>{
  'providerState': _contractJsonMap(_adeleValue297.providerState, 'map'),
};
EnvironmentProviderResult _decodeEnvironmentProviderResult(
  Object? _adeleValue300,
) {
  final _adeleMap301 = _contractMap(
    _adeleValue300,
    'EnvironmentProviderResult',
  );
  _contractFields(_adeleMap301, const {
    'providerState',
  }, 'EnvironmentProviderResult');
  final _adeleField302 = _contractJsonMap(
    _adeleMap301['providerState'],
    'providerState',
  );
  return _contractConstruct(
    'EnvironmentProviderResult',
    () => EnvironmentProviderResult(providerState: _adeleField302),
  );
}

const String environmentTextFileTypeId = 'environment.textFile';
Map<String, Object?> _encodeEnvironmentTextFile(
  EnvironmentTextFile _adeleValue305,
) => <String, Object?>{
  'relativePath': _adeleValue305.relativePath,
  'revision': _adeleValue305.revision,
  'sizeBytes': _adeleValue305.sizeBytes,
  'text': _adeleValue305.text,
};
EnvironmentTextFile _decodeEnvironmentTextFile(Object? _adeleValue314) {
  final _adeleMap315 = _contractMap(_adeleValue314, 'EnvironmentTextFile');
  _contractFields(_adeleMap315, const {
    'relativePath',
    'revision',
    'sizeBytes',
    'text',
  }, 'EnvironmentTextFile');
  final _adeleField316 = _contractString(
    _adeleMap315['relativePath'],
    'relativePath',
  );
  final _adeleField317 = _contractString(_adeleMap315['revision'], 'revision');
  final _adeleField318 = _contractInt(_adeleMap315['sizeBytes'], 'sizeBytes');
  final _adeleField319 = _contractString(_adeleMap315['text'], 'text');
  return _contractConstruct(
    'EnvironmentTextFile',
    () => EnvironmentTextFile(
      relativePath: _adeleField316,
      revision: _adeleField317,
      sizeBytes: _adeleField318,
      text: _adeleField319,
    ),
  );
}

const String environmentTextFileCreationTypeId = 'environment.textFileCreation';
Map<String, Object?> _encodeEnvironmentTextFileCreation(
  EnvironmentTextFileCreation _adeleValue328,
) => <String, Object?>{'revision': _adeleValue328.revision};
EnvironmentTextFileCreation _decodeEnvironmentTextFileCreation(
  Object? _adeleValue331,
) {
  final _adeleMap332 = _contractMap(
    _adeleValue331,
    'EnvironmentTextFileCreation',
  );
  _contractFields(_adeleMap332, const {
    'revision',
  }, 'EnvironmentTextFileCreation');
  final _adeleField333 = _contractString(_adeleMap332['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileCreation',
    () => EnvironmentTextFileCreation(revision: _adeleField333),
  );
}

const String environmentTextFileReplacementTypeId =
    'environment.textFileReplacement';
Map<String, Object?> _encodeEnvironmentTextFileReplacement(
  EnvironmentTextFileReplacement _adeleValue336,
) => <String, Object?>{'revision': _adeleValue336.revision};
EnvironmentTextFileReplacement _decodeEnvironmentTextFileReplacement(
  Object? _adeleValue339,
) {
  final _adeleMap340 = _contractMap(
    _adeleValue339,
    'EnvironmentTextFileReplacement',
  );
  _contractFields(_adeleMap340, const {
    'revision',
  }, 'EnvironmentTextFileReplacement');
  final _adeleField341 = _contractString(_adeleMap340['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileReplacement',
    () => EnvironmentTextFileReplacement(revision: _adeleField341),
  );
}

EnvironmentDirectoryEntryKind _decodeEnvironmentDirectoryEntryKind(
  Object? _adeleValue344,
) {
  if (_adeleValue344 is! String)
    throw AdeleProtocolException('Expected EnvironmentDirectoryEntryKind.');
  return switch (_adeleValue344) {
    'file' => EnvironmentDirectoryEntryKind.file,
    'directory' => EnvironmentDirectoryEntryKind.directory,
    'other' => EnvironmentDirectoryEntryKind.other,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentDirectoryEntryKind: ' + _adeleValue344 + '.',
    ),
  };
}

EnvironmentProcessEventKind _decodeEnvironmentProcessEventKind(
  Object? _adeleValue345,
) {
  if (_adeleValue345 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessEventKind.');
  return switch (_adeleValue345) {
    'output' => EnvironmentProcessEventKind.output,
    'completed' => EnvironmentProcessEventKind.completed,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessEventKind: ' + _adeleValue345 + '.',
    ),
  };
}

EnvironmentProcessOutputStream _decodeEnvironmentProcessOutputStream(
  Object? _adeleValue346,
) {
  if (_adeleValue346 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessOutputStream.');
  return switch (_adeleValue346) {
    'stdout' => EnvironmentProcessOutputStream.stdout,
    'stderr' => EnvironmentProcessOutputStream.stderr,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessOutputStream: ' + _adeleValue346 + '.',
    ),
  };
}

EnvironmentProcessTermination _decodeEnvironmentProcessTermination(
  Object? _adeleValue347,
) {
  if (_adeleValue347 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessTermination.');
  return switch (_adeleValue347) {
    'exited' => EnvironmentProcessTermination.exited,
    'timedOut' => EnvironmentProcessTermination.timedOut,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessTermination: ' + _adeleValue347 + '.',
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
