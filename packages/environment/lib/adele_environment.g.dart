// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'adele_environment.dart';

const String authorizedEnvironmentMutationServiceId =
    'authorizedEnvironmentMutation';
const String authorizedEnvironmentMutationServiceCreateTextFileId =
    'authorizedEnvironmentMutation.createTextFile';
const String authorizedEnvironmentMutationServiceDeleteExistingTextFileId =
    'authorizedEnvironmentMutation.deleteExistingTextFile';
const String authorizedEnvironmentMutationServiceReplaceExistingTextFileId =
    'authorizedEnvironmentMutation.replaceExistingTextFile';

final class AuthorizedEnvironmentMutationServiceClient
    implements AuthorizedEnvironmentMutationService {
  const AuthorizedEnvironmentMutationServiceClient(
    AdeleRequestChannel _adeleChannel,
  ) : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) async {
    try {
      return _decodeEnvironmentTextFileCreation(
        await this._adeleChannel.request(
          authorizedEnvironmentMutationServiceCreateTextFileId,
          <String, Object?>{'relativePath': relativePath, 'text': text},
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
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) async {
    try {
      final _adeleResponse12 = await this._adeleChannel.request(
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId,
        <String, Object?>{
          'relativePath': relativePath,
          'expectedRevision': expectedRevision,
        },
      );
      _contractVoid(_adeleResponse12, 'deleteExistingTextFile');
      return;
    } on AdeleRemoteFailure catch (_adeleError7) {
      switch (_adeleError7.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError7.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError7.code,
              message: _adeleError7.message,
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
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) async {
    try {
      return _decodeEnvironmentTextFileReplacement(
        await this._adeleChannel.request(
          authorizedEnvironmentMutationServiceReplaceExistingTextFileId,
          <String, Object?>{
            'relativePath': relativePath,
            'replacementText': replacementText,
            'expectedRevision': expectedRevision,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError13) {
      switch (_adeleError13.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError13.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError13.code,
              message: _adeleError13.message,
              details: _adeleDetails0,
            ),
          );
        default:
          rethrow;
      }
    }
  }
}

abstract interface class AuthorizedEnvironmentMutationServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class AuthorizedEnvironmentMutationServiceDispatcher
    implements AuthorizedEnvironmentMutationServiceRequestDispatcher {
  AuthorizedEnvironmentMutationServiceDispatcher(this._adeleService);
  final AuthorizedEnvironmentMutationService _adeleService;
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
      authorizedEnvironmentMutationServiceCreateTextFileId,
      authorizedEnvironmentMutationServiceDeleteExistingTextFileId,
      authorizedEnvironmentMutationServiceReplaceExistingTextFileId,
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
        authorizedEnvironmentMutationServiceCreateTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
            'text',
          }, 'createTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(_adelePayload4['text'], 'text'),
          ];
        })(),
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
            'expectedRevision',
          }, 'deleteExistingTextFile payload');
          return <Object?>[
            _contractString(_adelePayload4['relativePath'], 'relativePath'),
            _contractString(
              _adelePayload4['expectedRevision'],
              'expectedRevision',
            ),
          ];
        })(),
        authorizedEnvironmentMutationServiceReplaceExistingTextFileId => (() {
          _contractFields(_adelePayload4, const {
            'relativePath',
            'replacementText',
            'expectedRevision',
          }, 'replaceExistingTextFile payload');
          return <Object?>[
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
        authorizedEnvironmentMutationServiceCreateTextFileId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.createTextFile(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
          );
        })(),
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId =>
          (() async {
            final _adeleValues0 = _adeleArguments6 as List<Object?>;
            await this._adeleService.deleteExistingTextFile(
              _adeleValues0[0] as String,
              _adeleValues0[1] as String,
            );
            return null;
          })(),
        authorizedEnvironmentMutationServiceReplaceExistingTextFileId =>
          (() async {
            final _adeleValues0 = _adeleArguments6 as List<Object?>;
            return await this._adeleService.replaceExistingTextFile(
              _adeleValues0[0] as String,
              _adeleValues0[1] as String,
              _adeleValues0[2] as String,
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
        authorizedEnvironmentMutationServiceCreateTextFileId =>
          _encodeEnvironmentTextFileCreation(
            (_adeleResult8 as EnvironmentTextFileCreation),
          ),
        authorizedEnvironmentMutationServiceDeleteExistingTextFileId => null,
        authorizedEnvironmentMutationServiceReplaceExistingTextFileId =>
          _encodeEnvironmentTextFileReplacement(
            (_adeleResult8 as EnvironmentTextFileReplacement),
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
    } on AdeleRemoteFailure catch (_adeleError42) {
      switch (_adeleError42.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError42.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError42.code,
              message: _adeleError42.message,
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
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    try {
      return _decodeEnvironmentTextFile(
        await this._adeleChannel.request(
          authorizedEnvironmentReadServiceReadFileId,
          <String, Object?>{'relativePath': relativePath},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError50) {
      switch (_adeleError50.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError50.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError50.code,
              message: _adeleError50.message,
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
    } on AdeleRemoteFailure catch (_adeleError65) {
      switch (_adeleError65.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError65.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError65.code,
              message: _adeleError65.message,
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
      final _adeleResponse81 = await this._adeleChannel.request(
        environmentProviderServiceDeleteExistingTextFileId,
        <String, Object?>{
          'environmentId': environmentId,
          'relativePath': relativePath,
          'expectedRevision': expectedRevision,
        },
      );
      _contractVoid(_adeleResponse81, 'deleteExistingTextFile');
      return;
    } on AdeleRemoteFailure catch (_adeleError74) {
      switch (_adeleError74.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError74.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError74.code,
              message: _adeleError74.message,
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
    } on AdeleRemoteFailure catch (_adeleError82) {
      switch (_adeleError82.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError82.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError82.code,
              message: _adeleError82.message,
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
    } on AdeleRemoteFailure catch (_adeleError87) {
      switch (_adeleError87.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError87.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError87.code,
              message: _adeleError87.message,
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
    } on AdeleRemoteFailure catch (_adeleError94) {
      switch (_adeleError94.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError94.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError94.code,
              message: _adeleError94.message,
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
    } on AdeleRemoteFailure catch (_adeleError101) {
      switch (_adeleError101.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError101.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError101.code,
              message: _adeleError101.message,
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
    } on AdeleRemoteFailure catch (_adeleError112) {
      switch (_adeleError112.declaredFailureType) {
        case environmentFailureTypeId:
          final _adeleDetails0 = _contractJsonMap(
            _adeleError112.details,
            'failure details',
          );
          throw _contractConstruct(
            'EnvironmentFailure',
            () => EnvironmentFailure(
              code: _adeleError112.code,
              message: _adeleError112.message,
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
    final _adeleRaw118 = _adeleStreamChannel4.stream(
      environmentProviderServiceRunForegroundProcessId,
      <String, Object?>{
        'environmentId': environmentId,
        'request': _encodeEnvironmentForegroundProcessRequest(request),
      },
    );
    return adeleDecodedStream<EnvironmentProcessEvent>(
      _adeleRaw118,
      (Object? _adeleItem5) => _decodeEnvironmentProcessEvent(_adeleItem5),
      (Object _adeleError117) {
        if (_adeleError117 is AdeleRemoteFailure) {
          switch (_adeleError117.declaredFailureType) {
            case environmentFailureTypeId:
              final _adeleDetails8 = _contractJsonMap(
                _adeleError117.details,
                'failure details',
              );
              throw _contractConstruct(
                'EnvironmentFailure',
                () => EnvironmentFailure(
                  code: _adeleError117.code,
                  message: _adeleError117.message,
                  details: _adeleDetails8,
                ),
              );
            default:
              break;
          }
        }
        return _adeleError117;
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
  AuthorizedEnvironmentIdentity _adeleValue177,
) => <String, Object?>{
  'environmentId': _adeleValue177.environmentId,
  'sessionId': _adeleValue177.sessionId,
};
AuthorizedEnvironmentIdentity _decodeAuthorizedEnvironmentIdentity(
  Object? _adeleValue182,
) {
  final _adeleMap183 = _contractMap(
    _adeleValue182,
    'AuthorizedEnvironmentIdentity',
  );
  _contractFields(_adeleMap183, const {
    'environmentId',
    'sessionId',
  }, 'AuthorizedEnvironmentIdentity');
  final _adeleField184 = _contractString(
    _adeleMap183['environmentId'],
    'environmentId',
  );
  final _adeleField185 = _contractString(
    _adeleMap183['sessionId'],
    'sessionId',
  );
  return _contractConstruct(
    'AuthorizedEnvironmentIdentity',
    () => AuthorizedEnvironmentIdentity(
      environmentId: _adeleField184,
      sessionId: _adeleField185,
    ),
  );
}

const String environmentTransportContextTypeId = 'environment.context';
Map<String, Object?> _encodeEnvironmentTransportContext(
  EnvironmentTransportContext _adeleValue190,
) => <String, Object?>{
  'environmentId': _adeleValue190.environmentId,
  'environmentRole': _adeleValue190.environmentRole,
  'projectId': _adeleValue190.projectId,
  'projectSourceLocation': _contractUriString(
    _adeleValue190.projectSourceLocation,
    'Uri',
  ),
  'providerId': _adeleValue190.providerId,
  'providerState': _contractJsonMap(_adeleValue190.providerState, 'map'),
  'providerStateInitialized': _adeleValue190.providerStateInitialized,
  'taskId': _adeleValue190.taskId,
  'taskTitle': _adeleValue190.taskTitle,
};
EnvironmentTransportContext _decodeEnvironmentTransportContext(
  Object? _adeleValue209,
) {
  final _adeleMap210 = _contractMap(
    _adeleValue209,
    'EnvironmentTransportContext',
  );
  _contractFields(_adeleMap210, const {
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
  final _adeleField211 = _contractString(
    _adeleMap210['environmentId'],
    'environmentId',
  );
  final _adeleField212 = _contractString(
    _adeleMap210['environmentRole'],
    'environmentRole',
  );
  final _adeleField213 = _contractString(
    _adeleMap210['projectId'],
    'projectId',
  );
  final _adeleField214 = _contractUri(
    _adeleMap210['projectSourceLocation'],
    'projectSourceLocation',
  );
  final _adeleField215 = _contractString(
    _adeleMap210['providerId'],
    'providerId',
  );
  final _adeleField216 = _contractJsonMap(
    _adeleMap210['providerState'],
    'providerState',
  );
  final _adeleField217 = _contractBool(
    _adeleMap210['providerStateInitialized'],
    'providerStateInitialized',
  );
  final _adeleField218 = _contractString(_adeleMap210['taskId'], 'taskId');
  final _adeleField219 = _contractString(
    _adeleMap210['taskTitle'],
    'taskTitle',
  );
  return _contractConstruct(
    'EnvironmentTransportContext',
    () => EnvironmentTransportContext(
      environmentId: _adeleField211,
      environmentRole: _adeleField212,
      projectId: _adeleField213,
      projectSourceLocation: _adeleField214,
      providerId: _adeleField215,
      providerState: _adeleField216,
      providerStateInitialized: _adeleField217,
      taskId: _adeleField218,
      taskTitle: _adeleField219,
    ),
  );
}

const String environmentDirectoryEntryTypeId = 'environment.directoryEntry';
Map<String, Object?> _encodeEnvironmentDirectoryEntry(
  EnvironmentDirectoryEntry _adeleValue238,
) => <String, Object?>{
  'kind': _adeleValue238.kind.name,
  'name': _adeleValue238.name,
  'relativePath': _adeleValue238.relativePath,
};
EnvironmentDirectoryEntry _decodeEnvironmentDirectoryEntry(
  Object? _adeleValue245,
) {
  final _adeleMap246 = _contractMap(
    _adeleValue245,
    'EnvironmentDirectoryEntry',
  );
  _contractFields(_adeleMap246, const {
    'kind',
    'name',
    'relativePath',
  }, 'EnvironmentDirectoryEntry');
  final _adeleField247 = _decodeEnvironmentDirectoryEntryKind(
    _adeleMap246['kind'],
  );
  final _adeleField248 = _contractString(_adeleMap246['name'], 'name');
  final _adeleField249 = _contractString(
    _adeleMap246['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryEntry',
    () => EnvironmentDirectoryEntry(
      kind: _adeleField247,
      name: _adeleField248,
      relativePath: _adeleField249,
    ),
  );
}

const String environmentDirectoryListingTypeId = 'environment.directoryListing';
Map<String, Object?> _encodeEnvironmentDirectoryListing(
  EnvironmentDirectoryListing _adeleValue256,
) => <String, Object?>{
  'entries': _adeleValue256.entries
      .map(
        (_adeleElement257) =>
            _encodeEnvironmentDirectoryEntry(_adeleElement257),
      )
      .toList(growable: false),
  'relativePath': _adeleValue256.relativePath,
};
EnvironmentDirectoryListing _decodeEnvironmentDirectoryListing(
  Object? _adeleValue263,
) {
  final _adeleMap264 = _contractMap(
    _adeleValue263,
    'EnvironmentDirectoryListing',
  );
  _contractFields(_adeleMap264, const {
    'entries',
    'relativePath',
  }, 'EnvironmentDirectoryListing');
  final _adeleField265 = List<EnvironmentDirectoryEntry>.unmodifiable(
    _contractList(_adeleMap264['entries'], 'entries').map(
      (_adeleElement267) => _decodeEnvironmentDirectoryEntry(_adeleElement267),
    ),
  );
  final _adeleField266 = _contractString(
    _adeleMap264['relativePath'],
    'relativePath',
  );
  return _contractConstruct(
    'EnvironmentDirectoryListing',
    () => EnvironmentDirectoryListing(
      entries: _adeleField265,
      relativePath: _adeleField266,
    ),
  );
}

const String environmentForegroundProcessRequestTypeId =
    'environment.foregroundProcessRequest';
Map<String, Object?> _encodeEnvironmentForegroundProcessRequest(
  EnvironmentForegroundProcessRequest _adeleValue273,
) => <String, Object?>{
  'arguments': _adeleValue273.arguments
      .map((_adeleElement274) => _adeleElement274)
      .toList(growable: false),
  'program': _adeleValue273.program,
  'relativeWorkingDirectory': _adeleValue273.relativeWorkingDirectory,
  'timeoutSeconds': _adeleValue273.timeoutSeconds,
};
EnvironmentForegroundProcessRequest _decodeEnvironmentForegroundProcessRequest(
  Object? _adeleValue284,
) {
  final _adeleMap285 = _contractMap(
    _adeleValue284,
    'EnvironmentForegroundProcessRequest',
  );
  _contractFields(_adeleMap285, const {
    'arguments',
    'program',
    'relativeWorkingDirectory',
    'timeoutSeconds',
  }, 'EnvironmentForegroundProcessRequest');
  final _adeleField286 = List<String>.unmodifiable(
    _contractList(_adeleMap285['arguments'], 'arguments').map(
      (_adeleElement290) =>
          _contractString(_adeleElement290, 'arguments element'),
    ),
  );
  final _adeleField287 = _contractString(_adeleMap285['program'], 'program');
  final _adeleField288 = _contractString(
    _adeleMap285['relativeWorkingDirectory'],
    'relativeWorkingDirectory',
  );
  final _adeleField289 = _contractInt(
    _adeleMap285['timeoutSeconds'],
    'timeoutSeconds',
  );
  return _contractConstruct(
    'EnvironmentForegroundProcessRequest',
    () => EnvironmentForegroundProcessRequest(
      arguments: _adeleField286,
      program: _adeleField287,
      relativeWorkingDirectory: _adeleField288,
      timeoutSeconds: _adeleField289,
    ),
  );
}

const String environmentProcessCompletedTypeId = 'environment.processCompleted';
Map<String, Object?> _encodeEnvironmentProcessCompleted(
  EnvironmentProcessCompleted _adeleValue300,
) => <String, Object?>{
  'exitCode': switch (_adeleValue300.exitCode) {
    final _adeleNonNullValue302? => _adeleNonNullValue302,
    null => null,
  },
  'stderrTruncated': _adeleValue300.stderrTruncated,
  'stdoutTruncated': _adeleValue300.stdoutTruncated,
  'termination': _adeleValue300.termination.name,
};
EnvironmentProcessCompleted _decodeEnvironmentProcessCompleted(
  Object? _adeleValue311,
) {
  final _adeleMap312 = _contractMap(
    _adeleValue311,
    'EnvironmentProcessCompleted',
  );
  _contractFields(_adeleMap312, const {
    'exitCode',
    'stderrTruncated',
    'stdoutTruncated',
    'termination',
  }, 'EnvironmentProcessCompleted');
  final _adeleField313 = switch (_adeleMap312['exitCode']) {
    final _adeleNonNullValue318? => _contractInt(
      _adeleNonNullValue318,
      'exitCode',
    ),
    null => null,
  };
  final _adeleField314 = _contractBool(
    _adeleMap312['stderrTruncated'],
    'stderrTruncated',
  );
  final _adeleField315 = _contractBool(
    _adeleMap312['stdoutTruncated'],
    'stdoutTruncated',
  );
  final _adeleField316 = _decodeEnvironmentProcessTermination(
    _adeleMap312['termination'],
  );
  return _contractConstruct(
    'EnvironmentProcessCompleted',
    () => EnvironmentProcessCompleted(
      exitCode: _adeleField313,
      stderrTruncated: _adeleField314,
      stdoutTruncated: _adeleField315,
      termination: _adeleField316,
    ),
  );
}

const String environmentProcessEventTypeId = 'environment.processEvent';
Map<String, Object?> _encodeEnvironmentProcessEvent(
  EnvironmentProcessEvent _adeleValue327,
) => <String, Object?>{
  'completed': switch (_adeleValue327.completed) {
    final _adeleNonNullValue329? => _encodeEnvironmentProcessCompleted(
      _adeleNonNullValue329,
    ),
    null => null,
  },
  'kind': _adeleValue327.kind.name,
  'output': switch (_adeleValue327.output) {
    final _adeleNonNullValue335? => _encodeEnvironmentProcessOutput(
      _adeleNonNullValue335,
    ),
    null => null,
  },
};
EnvironmentProcessEvent _decodeEnvironmentProcessEvent(Object? _adeleValue338) {
  final _adeleMap339 = _contractMap(_adeleValue338, 'EnvironmentProcessEvent');
  _contractFields(_adeleMap339, const {
    'completed',
    'kind',
    'output',
  }, 'EnvironmentProcessEvent');
  final _adeleField340 = switch (_adeleMap339['completed']) {
    final _adeleNonNullValue344? => _decodeEnvironmentProcessCompleted(
      _adeleNonNullValue344,
    ),
    null => null,
  };
  final _adeleField341 = _decodeEnvironmentProcessEventKind(
    _adeleMap339['kind'],
  );
  final _adeleField342 = switch (_adeleMap339['output']) {
    final _adeleNonNullValue350? => _decodeEnvironmentProcessOutput(
      _adeleNonNullValue350,
    ),
    null => null,
  };
  return _contractConstruct(
    'EnvironmentProcessEvent',
    () => EnvironmentProcessEvent(
      completed: _adeleField340,
      kind: _adeleField341,
      output: _adeleField342,
    ),
  );
}

const String environmentProcessOutputTypeId = 'environment.processOutput';
Map<String, Object?> _encodeEnvironmentProcessOutput(
  EnvironmentProcessOutput _adeleValue353,
) => <String, Object?>{
  'stream': _adeleValue353.stream.name,
  'text': _adeleValue353.text,
};
EnvironmentProcessOutput _decodeEnvironmentProcessOutput(
  Object? _adeleValue358,
) {
  final _adeleMap359 = _contractMap(_adeleValue358, 'EnvironmentProcessOutput');
  _contractFields(_adeleMap359, const {
    'stream',
    'text',
  }, 'EnvironmentProcessOutput');
  final _adeleField360 = _decodeEnvironmentProcessOutputStream(
    _adeleMap359['stream'],
  );
  final _adeleField361 = _contractString(_adeleMap359['text'], 'text');
  return _contractConstruct(
    'EnvironmentProcessOutput',
    () =>
        EnvironmentProcessOutput(stream: _adeleField360, text: _adeleField361),
  );
}

const String environmentProviderResultTypeId = 'environment.providerResult';
Map<String, Object?> _encodeEnvironmentProviderResult(
  EnvironmentProviderResult _adeleValue366,
) => <String, Object?>{
  'providerState': _contractJsonMap(_adeleValue366.providerState, 'map'),
};
EnvironmentProviderResult _decodeEnvironmentProviderResult(
  Object? _adeleValue369,
) {
  final _adeleMap370 = _contractMap(
    _adeleValue369,
    'EnvironmentProviderResult',
  );
  _contractFields(_adeleMap370, const {
    'providerState',
  }, 'EnvironmentProviderResult');
  final _adeleField371 = _contractJsonMap(
    _adeleMap370['providerState'],
    'providerState',
  );
  return _contractConstruct(
    'EnvironmentProviderResult',
    () => EnvironmentProviderResult(providerState: _adeleField371),
  );
}

const String environmentTextFileTypeId = 'environment.textFile';
Map<String, Object?> _encodeEnvironmentTextFile(
  EnvironmentTextFile _adeleValue374,
) => <String, Object?>{
  'relativePath': _adeleValue374.relativePath,
  'revision': _adeleValue374.revision,
  'sizeBytes': _adeleValue374.sizeBytes,
  'text': _adeleValue374.text,
};
EnvironmentTextFile _decodeEnvironmentTextFile(Object? _adeleValue383) {
  final _adeleMap384 = _contractMap(_adeleValue383, 'EnvironmentTextFile');
  _contractFields(_adeleMap384, const {
    'relativePath',
    'revision',
    'sizeBytes',
    'text',
  }, 'EnvironmentTextFile');
  final _adeleField385 = _contractString(
    _adeleMap384['relativePath'],
    'relativePath',
  );
  final _adeleField386 = _contractString(_adeleMap384['revision'], 'revision');
  final _adeleField387 = _contractInt(_adeleMap384['sizeBytes'], 'sizeBytes');
  final _adeleField388 = _contractString(_adeleMap384['text'], 'text');
  return _contractConstruct(
    'EnvironmentTextFile',
    () => EnvironmentTextFile(
      relativePath: _adeleField385,
      revision: _adeleField386,
      sizeBytes: _adeleField387,
      text: _adeleField388,
    ),
  );
}

const String environmentTextFileCreationTypeId = 'environment.textFileCreation';
Map<String, Object?> _encodeEnvironmentTextFileCreation(
  EnvironmentTextFileCreation _adeleValue397,
) => <String, Object?>{'revision': _adeleValue397.revision};
EnvironmentTextFileCreation _decodeEnvironmentTextFileCreation(
  Object? _adeleValue400,
) {
  final _adeleMap401 = _contractMap(
    _adeleValue400,
    'EnvironmentTextFileCreation',
  );
  _contractFields(_adeleMap401, const {
    'revision',
  }, 'EnvironmentTextFileCreation');
  final _adeleField402 = _contractString(_adeleMap401['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileCreation',
    () => EnvironmentTextFileCreation(revision: _adeleField402),
  );
}

const String environmentTextFileReplacementTypeId =
    'environment.textFileReplacement';
Map<String, Object?> _encodeEnvironmentTextFileReplacement(
  EnvironmentTextFileReplacement _adeleValue405,
) => <String, Object?>{'revision': _adeleValue405.revision};
EnvironmentTextFileReplacement _decodeEnvironmentTextFileReplacement(
  Object? _adeleValue408,
) {
  final _adeleMap409 = _contractMap(
    _adeleValue408,
    'EnvironmentTextFileReplacement',
  );
  _contractFields(_adeleMap409, const {
    'revision',
  }, 'EnvironmentTextFileReplacement');
  final _adeleField410 = _contractString(_adeleMap409['revision'], 'revision');
  return _contractConstruct(
    'EnvironmentTextFileReplacement',
    () => EnvironmentTextFileReplacement(revision: _adeleField410),
  );
}

EnvironmentDirectoryEntryKind _decodeEnvironmentDirectoryEntryKind(
  Object? _adeleValue413,
) {
  if (_adeleValue413 is! String)
    throw AdeleProtocolException('Expected EnvironmentDirectoryEntryKind.');
  return switch (_adeleValue413) {
    'file' => EnvironmentDirectoryEntryKind.file,
    'directory' => EnvironmentDirectoryEntryKind.directory,
    'other' => EnvironmentDirectoryEntryKind.other,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentDirectoryEntryKind: ' + _adeleValue413 + '.',
    ),
  };
}

EnvironmentProcessEventKind _decodeEnvironmentProcessEventKind(
  Object? _adeleValue414,
) {
  if (_adeleValue414 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessEventKind.');
  return switch (_adeleValue414) {
    'output' => EnvironmentProcessEventKind.output,
    'completed' => EnvironmentProcessEventKind.completed,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessEventKind: ' + _adeleValue414 + '.',
    ),
  };
}

EnvironmentProcessOutputStream _decodeEnvironmentProcessOutputStream(
  Object? _adeleValue415,
) {
  if (_adeleValue415 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessOutputStream.');
  return switch (_adeleValue415) {
    'stdout' => EnvironmentProcessOutputStream.stdout,
    'stderr' => EnvironmentProcessOutputStream.stderr,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessOutputStream: ' + _adeleValue415 + '.',
    ),
  };
}

EnvironmentProcessTermination _decodeEnvironmentProcessTermination(
  Object? _adeleValue416,
) {
  if (_adeleValue416 is! String)
    throw AdeleProtocolException('Expected EnvironmentProcessTermination.');
  return switch (_adeleValue416) {
    'exited' => EnvironmentProcessTermination.exited,
    'timedOut' => EnvironmentProcessTermination.timedOut,
    _ => throw AdeleProtocolException(
      'Unknown EnvironmentProcessTermination: ' + _adeleValue416 + '.',
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
