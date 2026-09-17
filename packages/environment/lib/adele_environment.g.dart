// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'adele_environment.dart';

const String authorizedEnvironmentReadServiceId = 'authorizedEnvironmentRead';
const String authorizedEnvironmentReadServiceAuthorityId =
    'authorizedEnvironmentRead.authority';
const String authorizedEnvironmentReadServiceReadDirectoryId =
    'authorizedEnvironmentRead.readDirectory';
const String authorizedEnvironmentReadServiceReadFileId =
    'authorizedEnvironmentRead.readFile';

final class AuthorizedEnvironmentReadServiceClient
    implements AuthorizedEnvironmentReadService {
  const AuthorizedEnvironmentReadServiceClient(
    AdeleRequestChannel _adeleChannel,
  ) : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    try {
      return _decodeAuthorizedEnvironmentIdentity(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceAuthorityId,
          <String, Object?>{},
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
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    try {
      return _decodeEnvironmentDirectoryListing(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceReadDirectoryId,
          <String, Object?>{'relativePath': relativePath},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError3) {
      switch (_adeleError3.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError3.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError3.code,
              message: _adeleError3.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    try {
      return _decodeEnvironmentTextFile(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceReadFileId,
          <String, Object?>{'relativePath': relativePath},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError8) {
      switch (_adeleError8.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError8.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError8.code,
              message: _adeleError8.message,
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
      authorizedEnvironmentReadServiceAuthorityId,
      authorizedEnvironmentReadServiceReadDirectoryId,
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
        authorizedEnvironmentReadServiceAuthorityId => (() {
          _contractFields(_adelePayload4, const {}, 'authority payload');
          return <Object?>[];
        })(),
        authorizedEnvironmentReadServiceReadDirectoryId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
          }, 'readDirectory payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
          ];
        })(),
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
        authorizedEnvironmentReadServiceAuthorityId => (() async {
          return await this._adeleService.authority();
        })(),
        authorizedEnvironmentReadServiceReadDirectoryId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.readDirectory(
            _adeleValues0[0] as String,
          );
        })(),
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
        authorizedEnvironmentReadServiceAuthorityId =>
          _encodeAuthorizedEnvironmentIdentity(
            (_adeleResult8 as AuthorizedEnvironmentIdentity),
          ),
        authorizedEnvironmentReadServiceReadDirectoryId =>
          _encodeEnvironmentDirectoryListing(
            (_adeleResult8 as EnvironmentDirectoryListing),
          ),
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
    } on AdeleRemoteFailure catch (_adeleError23) {
      switch (_adeleError23.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError23.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError23.code,
              message: _adeleError23.message,
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
      final _adeleResponse39 = await this._adeleChannel.request(
        environmentProviderServiceDeleteExistingTextFileId,
        <String, Object?>{
          'environmentId': environmentId,
          'relativePath': relativePath,
          'expectedRevision': expectedRevision,
        },
      );
      _contractVoid(_adeleResponse39, 'deleteExistingTextFile');
      return;
    } on AdeleRemoteFailure catch (_adeleError32) {
      switch (_adeleError32.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError32.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError32.code,
              message: _adeleError32.message,
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
    } on AdeleRemoteFailure catch (_adeleError40) {
      switch (_adeleError40.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError40.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError40.code,
              message: _adeleError40.message,
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
    } on AdeleRemoteFailure catch (_adeleError52) {
      switch (_adeleError52.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError52.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError52.code,
              message: _adeleError52.message,
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
    } on AdeleRemoteFailure catch (_adeleError59) {
      switch (_adeleError59.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError59.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError59.code,
              message: _adeleError59.message,
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
    } on AdeleRemoteFailure catch (_adeleError70) {
      switch (_adeleError70.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError70.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError70.code,
              message: _adeleError70.message,
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
    final _adeleRaw76 = _adeleStreamChannel4.stream(
      environmentProviderServiceRunForegroundProcessId,
      <String, Object?>{
        'environmentId': environmentId,
        'request': _encodeEnvironmentForegroundProcessRequest(request),
      },
    );
    return adeleDecodedStream<EnvironmentProcessEvent>(
      _adeleRaw76,
      (Object? _adeleItem5) => _decodeEnvironmentProcessEvent(_adeleItem5),
      (Object _adeleError75) {
        if (_adeleError75 is AdeleRemoteFailure) {
          switch (_adeleError75.declaredFailureType) {
            case environmentFailureTypeId:
              final _adeleDetails8 = _contractJsonMap(
                _adeleError75.details,
                'failure details',
              );
              throw _contractConstruct(
                'EnvironmentFailure',
                () => EnvironmentFailure(
                  code: _adeleError75.code,
                  message: _adeleError75.message,
                  details: _adeleDetails8,
                ),
              );
            default:
              break;
          }
        }
        return _adeleError75;
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
const String authorizedEnvironmentIdentityTypeId =
    'environment.authorizedIdentity';
Map<String, Object?> _encodeAuthorizedEnvironmentIdentity(
  AuthorizedEnvironmentIdentity _adeleValue135,
) => <String, Object?>{
  'environmentId': _adeleValue135.environmentId,
  'sessionId': _adeleValue135.sessionId,
};
AuthorizedEnvironmentIdentity _decodeAuthorizedEnvironmentIdentity(
  Object? _adeleValue140,
) {
  final _adeleMap141 = _contractMap(
    _adeleValue140,
    'AuthorizedEnvironmentIdentity',
  );
  _contractFields(_adeleMap141, const {
    'environmentId',
    'sessionId',
  }, 'AuthorizedEnvironmentIdentity');
  final _adeleField142 = _contractString(
    _adeleMap141['environmentId'],
    'environmentId',
  );
  final _adeleField143 = _contractString(
    _adeleMap141['sessionId'],
    'sessionId',
  );
  return _contractConstruct(
    'AuthorizedEnvironmentIdentity',
    () => AuthorizedEnvironmentIdentity(
      environmentId: _adeleField142,
      sessionId: _adeleField143,
    ),
  );
}

const String environmentTransportContextTypeId = 'environment.context';
Map<String, Object?> _encodeEnvironmentTransportContext(
  EnvironmentTransportContext _adeleValue148,
) => <String, Object?>{
  'environmentId': _adeleValue148.environmentId,
  'environmentRole': _adeleValue148.environmentRole,
  'projectId': _adeleValue148.projectId,
  'projectSourceLocation': _contractUriString(
    _adeleValue148.projectSourceLocation,
    'Uri',
  ),
  'providerId': _adeleValue148.providerId,
  'providerState': _contractJsonMap(_adeleValue148.providerState, 'map'),
  'providerStateInitialized': _adeleValue148.providerStateInitialized,
  'taskId': _adeleValue148.taskId,
  'taskTitle': _adeleValue148.taskTitle,
};
EnvironmentTransportContext _decodeEnvironmentTransportContext(
  Object? _adeleValue167,
) {
  final _adeleMap168 = _contractMap(
    _adeleValue167,
    'EnvironmentTransportContext',
  );
  _contractFields(_adeleMap168, const {
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
  final _adeleField169 = _contractString(
    _adeleMap168['environmentId'],
    'environmentId',
  );
  final _adeleField170 = _contractString(
    _adeleMap168['environmentRole'],
    'environmentRole',
  );
  final _adeleField171 = _contractString(
    _adeleMap168['projectId'],
    'projectId',
  );
  final _adeleField172 = _contractUri(
    _adeleMap168['projectSourceLocation'],
    'projectSourceLocation',
  );
  final _adeleField173 = _contractString(
    _adeleMap168['providerId'],
    'providerId',
  );
  final _adeleField174 = _contractJsonMap(
    _adeleMap168['providerState'],
    'providerState',
  );
  final _adeleField175 = _contractBool(
    _adeleMap168['providerStateInitialized'],
    'providerStateInitialized',
  );
  final _adeleField176 = _contractString(_adeleMap168['taskId'], 'taskId');
  final _adeleField177 = _contractString(
    _adeleMap168['taskTitle'],
    'taskTitle',
  );
  return _contractConstruct(
    'EnvironmentTransportContext',
    () => EnvironmentTransportContext(
      environmentId: _adeleField169,
      environmentRole: _adeleField170,
      projectId: _adeleField171,
      projectSourceLocation: _adeleField172,
      providerId: _adeleField173,
      providerState: _adeleField174,
      providerStateInitialized: _adeleField175,
      taskId: _adeleField176,
      taskTitle: _adeleField177,
    ),
  );
}

const String environmentDirectoryEntryTypeId = 'environment.directoryEntry';
Map<String, Object?> _encodeEnvironmentDirectoryEntry(
  EnvironmentDirectoryEntry _adeleValue196,
) => <String, Object?>{
  'kind': _adeleValue196.kind.name,
  'name': _adeleValue196.name,
  'relativePath': _adeleValue196.relativePath,
};
EnvironmentDirectoryEntry _decodeEnvironmentDirectoryEntry(
  Object? _adeleValue203,
) {
  final _adeleMap204 = _contractMap(
    _adeleValue203,
    'EnvironmentDirectoryEntry',
  );
  _contractFields(_adeleMap204, const {
    'kind',
    'name',
    'relativePath',
  }, 'EnvironmentDirectoryEntry');
  final _adeleField205 = _decodeEnvironmentDirectoryEntryKind(
    _adeleMap204['kind'],
  );
  final _adeleField206 = _contractString(_adeleMap204['name'], 'name');
  final _adeleField207 = _contractString(
    _adeleMap204['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryEntry',
    () => EnvironmentDirectoryEntry(
      kind: _adeleField205,
      name: _adeleField206,
      relativePath: _adeleField207,
    ),
  );
}

const String environmentDirectoryListingTypeId = 'environment.directoryListing';
Map<String, Object?> _encodeEnvironmentDirectoryListing(
  EnvironmentDirectoryListing _adeleValue214,
) => <String, Object?>{
  'entries': _adeleValue214.entries
      .map(
        (_adeleElement215) =>
            _encodeEnvironmentDirectoryEntry(_adeleElement215),
      )
      .toList(growable: false),
  'relativePath': _adeleValue214.relativePath,
};
EnvironmentDirectoryListing _decodeEnvironmentDirectoryListing(
  Object? _adeleValue221,
) {
  final _adeleMap222 = _contractMap(
    _adeleValue221,
    'EnvironmentDirectoryListing',
  );
  _contractFields(_adeleMap222, const {
    'entries',
    'relativePath',
  }, 'EnvironmentDirectoryListing');
  final _adeleField223 = List<EnvironmentDirectoryEntry>.unmodifiable(
    _contractList(_adeleMap222['entries'], 'entries').map(
      (_adeleElement225) => _decodeEnvironmentDirectoryEntry(_adeleElement225),
    ),
  );
  final _adeleField224 = _contractString(
    _adeleMap222['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryListing',
    () => EnvironmentDirectoryListing(
      entries: _adeleField223,
      relativePath: _adeleField224,
    ),
  );
}

const String environmentForegroundProcessRequestTypeId =
    'environment.foregroundProcessRequest';
Map<String, Object?> _encodeEnvironmentForegroundProcessRequest(
  EnvironmentForegroundProcessRequest _adeleValue231,
) => <String, Object?>{
  'arguments': _adeleValue231.arguments
      .map((_adeleElement232) => _adeleElement232)
      .toList(growable: false),
  'program': _adeleValue231.program,
  'relativeWorkingDirectory': _adeleValue231.relativeWorkingDirectory,
  'timeoutSeconds': _adeleValue231.timeoutSeconds,
};
EnvironmentForegroundProcessRequest _decodeEnvironmentForegroundProcessRequest(
  Object? _adeleValue242,
) {
  final _adeleMap243 = _contractMap(
    _adeleValue242,
    'EnvironmentForegroundProcessRequest',
  );
  _contractFields(_adeleMap243, const {
    'arguments',
    'program',
    'relativeWorkingDirectory',
    'timeoutSeconds',
  }, 'EnvironmentForegroundProcessRequest');
  final _adeleField244 = List<String>.unmodifiable(
    _contractList(_adeleMap243['arguments'], 'arguments').map(
      (_adeleElement248) =>
          _contractString(_adeleElement248, 'arguments element'),
    ),
  );
  final _adeleField245 = _contractString(_adeleMap243['program'], 'program');
  final _adeleField246 = _contractString(
    _adeleMap243['relativeWorkingDirectory'],
    'relativeWorkingDirectory',
  );
  final _adeleField247 = _contractInt(
    _adeleMap243['timeoutSeconds'],
    'timeoutSeconds',
  );
  return _contractConstruct(
    'EnvironmentForegroundProcessRequest',
    () => EnvironmentForegroundProcessRequest(
      arguments: _adeleField244,
      program: _adeleField245,
      relativeWorkingDirectory: _adeleField246,
      timeoutSeconds: _adeleField247,
    ),
  );
}

const String environmentProcessCompletedTypeId = 'environment.processCompleted';
Map<String, Object?> _encodeEnvironmentProcessCompleted(
  EnvironmentProcessCompleted _adeleValue258,
) => <String, Object?>{
  'exitCode': switch (_adeleValue258.exitCode) {
    final _adeleNonNullValue260? => _adeleNonNullValue260,
    null => null,
  },
  'stderrTruncated': _adeleValue258.stderrTruncated,
  'stdoutTruncated': _adeleValue258.stdoutTruncated,
  'termination': _adeleValue258.termination.name,
};
EnvironmentProcessCompleted _decodeEnvironmentProcessCompleted(
  Object? _adeleValue269,
) {
  final _adeleMap270 = _contractMap(
    _adeleValue269,
    'EnvironmentProcessCompleted',
  );
  _contractFields(_adeleMap270, const {
    'exitCode',
    'stderrTruncated',
    'stdoutTruncated',
    'termination',
  }, 'EnvironmentProcessCompleted');
  final _adeleField271 = switch (_adeleMap270['exitCode']) {
    final _adeleNonNullValue276? => _contractInt(
      _adeleNonNullValue276,
      'exitCode',
    ),
    null => null,
  };
  final _adeleField272 = _contractBool(
    _adeleMap270['stderrTruncated'],
    'stderrTruncated',
  );
  final _adeleField273 = _contractBool(
    _adeleMap270['stdoutTruncated'],
    'stdoutTruncated',
  );
  final _adeleField274 = _decodeEnvironmentProcessTermination(
    _adeleMap270['termination'],
  );
  return _contractConstruct(
    'EnvironmentProcessCompleted',
    () => EnvironmentProcessCompleted(
      exitCode: _adeleField271,
      stderrTruncated: _adeleField272,
      stdoutTruncated: _adeleField273,
      termination: _adeleField274,
    ),
  );
}

const String environmentProcessEventTypeId = 'environment.processEvent';
Map<String, Object?> _encodeEnvironmentProcessEvent(
  EnvironmentProcessEvent _adeleValue285,
) => <String, Object?>{
  'completed': switch (_adeleValue285.completed) {
    final _adeleNonNullValue287? => _encodeEnvironmentProcessCompleted(
      _adeleNonNullValue287,
    ),
    null => null,
  },
  'kind': _adeleValue285.kind.name,
  'output': switch (_adeleValue285.output) {
    final _adeleNonNullValue293? => _encodeEnvironmentProcessOutput(
      _adeleNonNullValue293,
    ),
    null => null,
  },
};
EnvironmentProcessEvent _decodeEnvironmentProcessEvent(Object? _adeleValue296) {
  final _adeleMap297 = _contractMap(_adeleValue296, 'EnvironmentProcessEvent');
  _contractFields(_adeleMap297, const {
    'completed',
    'kind',
    'output',
  }, 'EnvironmentProcessEvent');
  final _adeleField298 = switch (_adeleMap297['completed']) {
    final _adeleNonNullValue302? => _decodeEnvironmentProcessCompleted(
      _adeleNonNullValue302,
    ),
    null => null,
  };
  final _adeleField299 = _decodeEnvironmentProcessEventKind(
    _adeleMap297['kind'],
  );
  final _adeleField300 = switch (_adeleMap297['output']) {
    final _adeleNonNullValue308? => _decodeEnvironmentProcessOutput(
      _adeleNonNullValue308,
    ),
    null => null,
  };
  return _contractConstruct(
    'EnvironmentProcessEvent',
    () => EnvironmentProcessEvent(
      completed: _adeleField298,
      kind: _adeleField299,
      output: _adeleField300,
    ),
  );
}

const String environmentProcessOutputTypeId = 'environment.processOutput';
Map<String, Object?> _encodeEnvironmentProcessOutput(
  EnvironmentProcessOutput _adeleValue311,
) => <String, Object?>{
  'stream': _adeleValue311.stream.name,
  'text': _adeleValue311.text,
};
EnvironmentProcessOutput _decodeEnvironmentProcessOutput(
  Object? _adeleValue316,
) {
  final _adeleMap317 = _contractMap(_adeleValue316, 'EnvironmentProcessOutput');
  _contractFields(_adeleMap317, const {
    'stream',
    'text',
  }, 'EnvironmentProcessOutput');
  final _adeleField318 = _decodeEnvironmentProcessOutputStream(
    _adeleMap317['stream'],
  );
  final _adeleField319 = _contractString(_adeleMap317['text'], 'text');
  return _contractConstruct(
    'EnvironmentProcessOutput',
    () =>
        EnvironmentProcessOutput(stream: _adeleField318, text: _adeleField319),
  );
}

const String environmentProviderResultTypeId = 'environment.providerResult';
Map<String, Object?> _encodeEnvironmentProviderResult(
  EnvironmentProviderResult _adeleValue324,
) => <String, Object?>{
  'providerState': _contractJsonMap(_adeleValue324.providerState, 'map'),
};
EnvironmentProviderResult _decodeEnvironmentProviderResult(
  Object? _adeleValue327,
) {
  final _adeleMap328 = _contractMap(
    _adeleValue327,
    'EnvironmentProviderResult',
  );
  _contractFields(_adeleMap328, const {
    'providerState',
  }, 'EnvironmentProviderResult');
  final _adeleField329 = _contractJsonMap(
    _adeleMap328['providerState'],
    'providerState',
  );
  return _contractConstruct(
    'EnvironmentProviderResult',
    () => EnvironmentProviderResult(providerState: _adeleField329),
  );
}

const String environmentTextFileTypeId = 'environment.textFile';
Map<String, Object?> _encodeEnvironmentTextFile(
  EnvironmentTextFile _adeleValue332,
) => <String, Object?>{
  'relativePath': _adeleValue332.relativePath,
  'revision': _adeleValue332.revision,
  'sizeBytes': _adeleValue332.sizeBytes,
  'text': _adeleValue332.text,
};
EnvironmentTextFile _decodeEnvironmentTextFile(Object? _adeleValue341) {
  final _adeleMap342 = _contractMap(_adeleValue341, 'EnvironmentTextFile');
  _contractFields(_adeleMap342, const {
    'relativePath',
    'revision',
    'sizeBytes',
    'text',
  }, 'EnvironmentTextFile');
  final _adeleField343 = _contractString(
    _adeleMap342['relativePath'],
    'relativePath',
  );
  final _adeleField344 = _contractString(_adeleMap342['revision'], 'revision');
  final _adeleField345 = _contractInt(_adeleMap342['sizeBytes'], 'sizeBytes');
  final _adeleField346 = _contractString(_adeleMap342['text'], 'text');
  return _contractConstruct(
    'EnvironmentTextFile',
    () => EnvironmentTextFile(
      relativePath: _adeleField343,
      revision: _adeleField344,
      sizeBytes: _adeleField345,
      text: _adeleField346,
    ),
  );
}

const String environmentTextFileCreationTypeId = 'environment.textFileCreation';
Map<String, Object?> _encodeEnvironmentTextFileCreation(
  EnvironmentTextFileCreation _adeleValue355,
) => <String, Object?>{'revision': _adeleValue355.revision};
EnvironmentTextFileCreation _decodeEnvironmentTextFileCreation(
  Object? _adeleValue358,
) {
  final _adeleMap359 = _contractMap(
    _adeleValue358,
    'EnvironmentTextFileCreation',
  );
  _contractFields(_adeleMap359, const {
    'revision',
  }, 'EnvironmentTextFileCreation');
  final _adeleField360 = _contractString(_adeleMap359['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileCreation',
    () => EnvironmentTextFileCreation(revision: _adeleField360),
  );
}

const String environmentTextFileReplacementTypeId =
    'environment.textFileReplacement';
Map<String, Object?> _encodeEnvironmentTextFileReplacement(
  EnvironmentTextFileReplacement _adeleValue363,
) => <String, Object?>{'revision': _adeleValue363.revision};
EnvironmentTextFileReplacement _decodeEnvironmentTextFileReplacement(
  Object? _adeleValue366,
) {
  final _adeleMap367 = _contractMap(
    _adeleValue366,
    'EnvironmentTextFileReplacement',
  );
  _contractFields(_adeleMap367, const {
    'revision',
  }, 'EnvironmentTextFileReplacement');
  final _adeleField368 = _contractString(_adeleMap367['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileReplacement',
    () => EnvironmentTextFileReplacement(revision: _adeleField368),
  );
}

EnvironmentDirectoryEntryKind _decodeEnvironmentDirectoryEntryKind(
  Object? _adeleValue371,
) {
  if (_adeleValue371 is! String)
    throw AdeleProtocolException('Expected EnvironmentDirectoryEntryKind.');
  return switch (_adeleValue371) {
    'file' => EnvironmentDirectoryEntryKind.file,
    'directory' => EnvironmentDirectoryEntryKind.directory,
    'other' => EnvironmentDirectoryEntryKind.other,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentDirectoryEntryKind: ' + _adeleValue371 + '.',
    ),
  };
}

EnvironmentProcessEventKind _decodeEnvironmentProcessEventKind(
  Object? _adeleValue372,
) {
  if (_adeleValue372 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessEventKind.');
  return switch (_adeleValue372) {
    'output' => EnvironmentProcessEventKind.output,
    'completed' => EnvironmentProcessEventKind.completed,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessEventKind: ' + _adeleValue372 + '.',
    ),
  };
}

EnvironmentProcessOutputStream _decodeEnvironmentProcessOutputStream(
  Object? _adeleValue373,
) {
  if (_adeleValue373 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessOutputStream.');
  return switch (_adeleValue373) {
    'stdout' => EnvironmentProcessOutputStream.stdout,
    'stderr' => EnvironmentProcessOutputStream.stderr,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessOutputStream: ' + _adeleValue373 + '.',
    ),
  };
}

EnvironmentProcessTermination _decodeEnvironmentProcessTermination(
  Object? _adeleValue374,
) {
  if (_adeleValue374 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessTermination.');
  return switch (_adeleValue374) {
    'exited' => EnvironmentProcessTermination.exited,
    'timedOut' => EnvironmentProcessTermination.timedOut,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessTermination: ' + _adeleValue374 + '.',
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
