// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: curly_braces_in_flow_control_structures, dead_code, no_leading_underscores_for_local_identifiers, prefer_interpolation_to_compose_strings, unnecessary_nullable_for_final_variable_declarations, unnecessary_this, unused_catch_clause, unused_element, unused_local_variable, use_null_aware_elements

part of 'remote_orchestration.dart';

const String remoteOrchestrationHostServiceId = 'orchestrationExecutionHost';
const String remoteOrchestrationHostServiceApplyCurrentApprovalId =
    'orchestrationExecutionHost.applyCurrentApproval';
const String remoteOrchestrationHostServiceInvokeModelId =
    'orchestrationExecutionHost.invokeModel';
const String remoteOrchestrationHostServiceProcessProposalId =
    'orchestrationExecutionHost.processProposal';
const String remoteOrchestrationHostServiceTransitionId =
    'orchestrationExecutionHost.transition';

final class RemoteOrchestrationHostServiceClient
    implements RemoteOrchestrationHostService {
  const RemoteOrchestrationHostServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<RemoteSemanticModelInput> applyCurrentApproval() async {
    try {
      return _decodeRemoteSemanticModelInput(
        await this._adeleChannel.request(
          remoteOrchestrationHostServiceApplyCurrentApprovalId,
          <String, Object?>{},
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError0) {
      switch (_adeleError0.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }

  @override
  Future<RemoteStrategyModelTurn> invokeModel(
    RemoteStrategyInferenceMaterial material,
  ) async {
    try {
      return _decodeRemoteStrategyModelTurn(
        await this._adeleChannel.request(
          remoteOrchestrationHostServiceInvokeModelId,
          <String, Object?>{
            'material': _encodeRemoteStrategyInferenceMaterial(material),
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError3) {
      switch (_adeleError3.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }

  @override
  Future<RemoteStrategyToolResult> processProposal(
    String toolSnapshotHandle,
    String proposalHandle,
  ) async {
    try {
      return _decodeRemoteStrategyToolResult(
        await this._adeleChannel.request(
          remoteOrchestrationHostServiceProcessProposalId,
          <String, Object?>{
            'toolSnapshotHandle': toolSnapshotHandle,
            'proposalHandle': proposalHandle,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError8) {
      switch (_adeleError8.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }

  @override
  Future<RemoteRunState> transition(
    RemoteRunTransition transition,
    RemoteOrchestrationFailure? failure,
  ) async {
    try {
      return _decodeRemoteRunState(
        await this._adeleChannel.request(
          remoteOrchestrationHostServiceTransitionId,
          <String, Object?>{
            'transition': transition.name,
            'failure': switch (failure) {
              final _adeleNonNullValue19? => _encodeRemoteOrchestrationFailure(
                _adeleNonNullValue19,
              ),
              null => null,
            },
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError15) {
      switch (_adeleError15.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }
}

abstract interface class RemoteOrchestrationHostServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class RemoteOrchestrationHostServiceDispatcher
    implements RemoteOrchestrationHostServiceRequestDispatcher {
  RemoteOrchestrationHostServiceDispatcher(this._adeleService);
  final RemoteOrchestrationHostService _adeleService;
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
      remoteOrchestrationHostServiceApplyCurrentApprovalId,
      remoteOrchestrationHostServiceInvokeModelId,
      remoteOrchestrationHostServiceProcessProposalId,
      remoteOrchestrationHostServiceTransitionId,
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
        remoteOrchestrationHostServiceApplyCurrentApprovalId => (() {
          _contractFields(
            _adelePayload4,
            const {},
            'applyCurrentApproval payload',
          );
          return <Object?>[];
        })(),
        remoteOrchestrationHostServiceInvokeModelId => (() {
          _contractFields(_adelePayload4, const {
            'material',
          }, 'invokeModel payload');
          return <Object?>[
            _decodeRemoteStrategyInferenceMaterial(_adelePayload4['material']),
          ];
        })(),
        remoteOrchestrationHostServiceProcessProposalId => (() {
          _contractFields(_adelePayload4, const {
            'toolSnapshotHandle',
            'proposalHandle',
          }, 'processProposal payload');
          return <Object?>[
            _contractString(
              _adelePayload4['toolSnapshotHandle'],
              'toolSnapshotHandle',
            ),
            _contractString(_adelePayload4['proposalHandle'], 'proposalHandle'),
          ];
        })(),
        remoteOrchestrationHostServiceTransitionId => (() {
          _contractFields(_adelePayload4, const {
            'transition',
            'failure',
          }, 'transition payload');
          return <Object?>[
            _decodeRemoteRunTransition(_adelePayload4['transition']),
            switch (_adelePayload4['failure']) {
              final _adeleNonNullValue33? => _decodeRemoteOrchestrationFailure(
                _adeleNonNullValue33,
              ),
              null => null,
            },
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
        remoteOrchestrationHostServiceApplyCurrentApprovalId => (() async {
          return await this._adeleService.applyCurrentApproval();
        })(),
        remoteOrchestrationHostServiceInvokeModelId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.invokeModel(
            _adeleValues0[0] as RemoteStrategyInferenceMaterial,
          );
        })(),
        remoteOrchestrationHostServiceProcessProposalId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.processProposal(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
          );
        })(),
        remoteOrchestrationHostServiceTransitionId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.transition(
            _adeleValues0[0] as RemoteRunTransition,
            _adeleValues0[1] as RemoteOrchestrationFailure?,
          );
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
        remoteOrchestrationHostServiceApplyCurrentApprovalId =>
          _encodeRemoteSemanticModelInput(
            (_adeleResult8 as RemoteSemanticModelInput),
          ),
        remoteOrchestrationHostServiceInvokeModelId =>
          _encodeRemoteStrategyModelTurn(
            (_adeleResult8 as RemoteStrategyModelTurn),
          ),
        remoteOrchestrationHostServiceProcessProposalId =>
          _encodeRemoteStrategyToolResult(
            (_adeleResult8 as RemoteStrategyToolResult),
          ),
        remoteOrchestrationHostServiceTransitionId =>
          (_adeleResult8 as RemoteRunState).name,
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

const String remoteOrchestrationServiceId = 'orchestrationStrategy';
const String remoteOrchestrationServiceMaterializeId =
    'orchestrationStrategy.materialize';
const String remoteOrchestrationServiceReleaseId =
    'orchestrationStrategy.release';
const String remoteOrchestrationServiceResolveApprovalId =
    'orchestrationStrategy.resolveApproval';
const String remoteOrchestrationServiceStartId = 'orchestrationStrategy.start';

final class RemoteOrchestrationServiceClient
    implements RemoteOrchestrationService {
  const RemoteOrchestrationServiceClient(AdeleRequestChannel _adeleChannel)
    : _adeleChannel = _adeleChannel;
  final AdeleRequestChannel _adeleChannel;
  @override
  Future<String> materialize(
    String routeId,
    RemoteOrchestrationSession session,
    String runId,
  ) async {
    try {
      return _contractString(
        await this._adeleChannel
            .request(remoteOrchestrationServiceMaterializeId, <String, Object?>{
              'routeId': routeId,
              'session': _encodeRemoteOrchestrationSession(session),
              'runId': runId,
            }),
        'materialize',
      );
    } on AdeleRemoteFailure catch (_adeleError44) {
      switch (_adeleError44.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }

  @override
  Future<void> release(String executionId) async {
    try {
      final _adeleResponse56 = await this._adeleChannel.request(
        remoteOrchestrationServiceReleaseId,
        <String, Object?>{'executionId': executionId},
      );
      _contractVoid(_adeleResponse56, 'release');
      return;
    } on AdeleRemoteFailure catch (_adeleError53) {
      switch (_adeleError53.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }

  @override
  Future<RemoteRunState> resolveApproval(
    String executionId,
    RemoteApprovalResolution resolution,
    String hostInvocationContext,
  ) async {
    try {
      return _decodeRemoteRunState(
        await this._adeleChannel.request(
          remoteOrchestrationServiceResolveApprovalId,
          <String, Object?>{
            'executionId': executionId,
            'resolution': _encodeRemoteApprovalResolution(resolution),
            'hostInvocationContext': hostInvocationContext,
          },
        ),
      );
    } on AdeleRemoteFailure catch (_adeleError57) {
      switch (_adeleError57.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }

  @override
  Future<RemoteRunState> start(
    String executionId,
    String hostInvocationContext,
  ) async {
    try {
      return _decodeRemoteRunState(
        await this._adeleChannel
            .request(remoteOrchestrationServiceStartId, <String, Object?>{
              'executionId': executionId,
              'hostInvocationContext': hostInvocationContext,
            }),
      );
    } on AdeleRemoteFailure catch (_adeleError66) {
      switch (_adeleError66.declaredFailureType) {
        default:
          rethrow;
      }
    }
  }
}

abstract interface class RemoteOrchestrationServiceRequestDispatcher
    implements AdeleBackendDispatcher {}

final class RemoteOrchestrationServiceDispatcher
    implements RemoteOrchestrationServiceRequestDispatcher {
  RemoteOrchestrationServiceDispatcher(this._adeleService);
  final RemoteOrchestrationService _adeleService;
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
      remoteOrchestrationServiceMaterializeId,
      remoteOrchestrationServiceReleaseId,
      remoteOrchestrationServiceResolveApprovalId,
      remoteOrchestrationServiceStartId,
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
        remoteOrchestrationServiceMaterializeId => (() {
          _contractFields(_adelePayload4, const {
            'routeId',
            'session',
            'runId',
          }, 'materialize payload');
          return <Object?>[
            _contractString(_adelePayload4['routeId'], 'routeId'),
            _decodeRemoteOrchestrationSession(_adelePayload4['session']),
            _contractString(_adelePayload4['runId'], 'runId'),
          ];
        })(),
        remoteOrchestrationServiceReleaseId => (() {
          _contractFields(_adelePayload4, const {
            'executionId',
          }, 'release payload');
          return <Object?>[
            _contractString(_adelePayload4['executionId'], 'executionId'),
          ];
        })(),
        remoteOrchestrationServiceResolveApprovalId => (() {
          _contractFields(_adelePayload4, const {
            'executionId',
            'resolution',
            'hostInvocationContext',
          }, 'resolveApproval payload');
          return <Object?>[
            _contractString(_adelePayload4['executionId'], 'executionId'),
            _decodeRemoteApprovalResolution(_adelePayload4['resolution']),
            _contractString(
              _adelePayload4['hostInvocationContext'],
              'hostInvocationContext',
            ),
          ];
        })(),
        remoteOrchestrationServiceStartId => (() {
          _contractFields(_adelePayload4, const {
            'executionId',
            'hostInvocationContext',
          }, 'start payload');
          return <Object?>[
            _contractString(_adelePayload4['executionId'], 'executionId'),
            _contractString(
              _adelePayload4['hostInvocationContext'],
              'hostInvocationContext',
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
        remoteOrchestrationServiceMaterializeId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.materialize(
            _adeleValues0[0] as String,
            _adeleValues0[1] as RemoteOrchestrationSession,
            _adeleValues0[2] as String,
          );
        })(),
        remoteOrchestrationServiceReleaseId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          await this._adeleService.release(_adeleValues0[0] as String);
          return null;
        })(),
        remoteOrchestrationServiceResolveApprovalId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.resolveApproval(
            _adeleValues0[0] as String,
            _adeleValues0[1] as RemoteApprovalResolution,
            _adeleValues0[2] as String,
          );
        })(),
        remoteOrchestrationServiceStartId => (() async {
          final _adeleValues0 = _adeleArguments6 as List<Object?>;
          return await this._adeleService.start(
            _adeleValues0[0] as String,
            _adeleValues0[1] as String,
          );
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
        remoteOrchestrationServiceMaterializeId => (_adeleResult8 as String),
        remoteOrchestrationServiceReleaseId => null,
        remoteOrchestrationServiceResolveApprovalId =>
          (_adeleResult8 as RemoteRunState).name,
        remoteOrchestrationServiceStartId =>
          (_adeleResult8 as RemoteRunState).name,
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
const String remoteApprovalResolutionTypeId =
    'orchestration.approvalResolution';
Map<String, Object?> _encodeRemoteApprovalResolution(
  RemoteApprovalResolution _adeleValue99,
) => <String, Object?>{
  'approved': _adeleValue99.approved,
  'interruptionId': _adeleValue99.interruptionId,
  'toolInvocationId': _adeleValue99.toolInvocationId,
};
RemoteApprovalResolution _decodeRemoteApprovalResolution(
  Object? _adeleValue106,
) {
  final _adeleMap107 = _contractMap(_adeleValue106, 'RemoteApprovalResolution');
  _contractFields(_adeleMap107, const {
    'approved',
    'interruptionId',
    'toolInvocationId',
  }, 'RemoteApprovalResolution');
  final _adeleField108 = _contractBool(_adeleMap107['approved'], 'approved');
  final _adeleField109 = _contractString(
    _adeleMap107['interruptionId'],
    'interruptionId',
  );
  final _adeleField110 = _contractString(
    _adeleMap107['toolInvocationId'],
    'toolInvocationId',
  );
  return _contractConstruct(
    'RemoteApprovalResolution',
    () => RemoteApprovalResolution(
      approved: _adeleField108,
      interruptionId: _adeleField109,
      toolInvocationId: _adeleField110,
    ),
  );
}

const String remoteOrchestrationFailureTypeId = 'orchestration.failure';
Map<String, Object?> _encodeRemoteOrchestrationFailure(
  RemoteOrchestrationFailure _adeleValue117,
) => <String, Object?>{
  'code': _adeleValue117.code,
  'message': _adeleValue117.message,
};
RemoteOrchestrationFailure _decodeRemoteOrchestrationFailure(
  Object? _adeleValue122,
) {
  final _adeleMap123 = _contractMap(
    _adeleValue122,
    'RemoteOrchestrationFailure',
  );
  _contractFields(_adeleMap123, const {
    'code',
    'message',
  }, 'RemoteOrchestrationFailure');
  final _adeleField124 = _contractString(_adeleMap123['code'], 'code');
  final _adeleField125 = _contractString(_adeleMap123['message'], 'message');
  return _contractConstruct(
    'RemoteOrchestrationFailure',
    () => RemoteOrchestrationFailure(
      code: _adeleField124,
      message: _adeleField125,
    ),
  );
}

const String remoteStrategyInferenceMaterialTypeId =
    'orchestration.inferenceMaterial';
Map<String, Object?> _encodeRemoteStrategyInferenceMaterial(
  RemoteStrategyInferenceMaterial _adeleValue130,
) => <String, Object?>{
  'input': _adeleValue130.input
      .map(
        (_adeleElement131) => _encodeRemoteSemanticModelInput(_adeleElement131),
      )
      .toList(growable: false),
  'instructions': _adeleValue130.instructions,
};
RemoteStrategyInferenceMaterial _decodeRemoteStrategyInferenceMaterial(
  Object? _adeleValue137,
) {
  final _adeleMap138 = _contractMap(
    _adeleValue137,
    'RemoteStrategyInferenceMaterial',
  );
  _contractFields(_adeleMap138, const {
    'input',
    'instructions',
  }, 'RemoteStrategyInferenceMaterial');
  final _adeleField139 = List<RemoteSemanticModelInput>.unmodifiable(
    _contractList(_adeleMap138['input'], 'input').map(
      (_adeleElement141) => _decodeRemoteSemanticModelInput(_adeleElement141),
    ),
  );
  final _adeleField140 = _contractString(
    _adeleMap138['instructions'],
    'instructions',
  );
  return _contractConstruct(
    'RemoteStrategyInferenceMaterial',
    () => RemoteStrategyInferenceMaterial(
      input: _adeleField139,
      instructions: _adeleField140,
    ),
  );
}

const String remoteModelTerminalMetadataTypeId = 'orchestration.modelMetadata';
Map<String, Object?> _encodeRemoteModelTerminalMetadata(
  RemoteModelTerminalMetadata _adeleValue147,
) => <String, Object?>{
  'payload': _contractJsonMap(_adeleValue147.payload, 'map'),
};
RemoteModelTerminalMetadata _decodeRemoteModelTerminalMetadata(
  Object? _adeleValue150,
) {
  final _adeleMap151 = _contractMap(
    _adeleValue150,
    'RemoteModelTerminalMetadata',
  );
  _contractFields(_adeleMap151, const {
    'payload',
  }, 'RemoteModelTerminalMetadata');
  final _adeleField152 = _contractJsonMap(_adeleMap151['payload'], 'payload');
  return _contractConstruct(
    'RemoteModelTerminalMetadata',
    () => RemoteModelTerminalMetadata(payload: _adeleField152),
  );
}

const String remoteModelOutputTypeId = 'orchestration.modelOutput';
Map<String, Object?> _encodeRemoteModelOutput(
  RemoteModelOutput _adeleValue155,
) => <String, Object?>{
  'kind': _adeleValue155.kind.name,
  'payload': _contractJsonMap(_adeleValue155.payload, 'map'),
  'proposalHandle': switch (_adeleValue155.proposalHandle) {
    final _adeleNonNullValue161? => _adeleNonNullValue161,
    null => null,
  },
};
RemoteModelOutput _decodeRemoteModelOutput(Object? _adeleValue164) {
  final _adeleMap165 = _contractMap(_adeleValue164, 'RemoteModelOutput');
  _contractFields(_adeleMap165, const {
    'kind',
    'payload',
    'proposalHandle',
  }, 'RemoteModelOutput');
  final _adeleField166 = _decodeRemoteModelOutputKind(_adeleMap165['kind']);
  final _adeleField167 = _contractJsonMap(_adeleMap165['payload'], 'payload');
  final _adeleField168 = switch (_adeleMap165['proposalHandle']) {
    final _adeleNonNullValue174? => _contractString(
      _adeleNonNullValue174,
      'proposalHandle',
    ),
    null => null,
  };
  return _contractConstruct(
    'RemoteModelOutput',
    () => RemoteModelOutput(
      kind: _adeleField166,
      payload: _adeleField167,
      proposalHandle: _adeleField168,
    ),
  );
}

const String remoteStrategyModelTurnTypeId = 'orchestration.modelTurn';
Map<String, Object?> _encodeRemoteStrategyModelTurn(
  RemoteStrategyModelTurn _adeleValue177,
) => <String, Object?>{
  'failure': switch (_adeleValue177.failure) {
    final _adeleNonNullValue179? => _encodeRemoteOrchestrationFailure(
      _adeleNonNullValue179,
    ),
    null => null,
  },
  'incompleteReason': switch (_adeleValue177.incompleteReason) {
    final _adeleNonNullValue183? => _adeleNonNullValue183.name,
    null => null,
  },
  'metadata': switch (_adeleValue177.metadata) {
    final _adeleNonNullValue187? => _encodeRemoteModelTerminalMetadata(
      _adeleNonNullValue187,
    ),
    null => null,
  },
  'output': _adeleValue177.output
      .map((_adeleElement190) => _encodeRemoteModelOutput(_adeleElement190))
      .toList(growable: false),
  'settlement': switch (_adeleValue177.settlement) {
    final _adeleNonNullValue195? => _adeleNonNullValue195.name,
    null => null,
  },
  'toolSnapshotHandle': _adeleValue177.toolSnapshotHandle,
};
RemoteStrategyModelTurn _decodeRemoteStrategyModelTurn(Object? _adeleValue200) {
  final _adeleMap201 = _contractMap(_adeleValue200, 'RemoteStrategyModelTurn');
  _contractFields(_adeleMap201, const {
    'failure',
    'incompleteReason',
    'metadata',
    'output',
    'settlement',
    'toolSnapshotHandle',
  }, 'RemoteStrategyModelTurn');
  final _adeleField202 = switch (_adeleMap201['failure']) {
    final _adeleNonNullValue209? => _decodeRemoteOrchestrationFailure(
      _adeleNonNullValue209,
    ),
    null => null,
  };
  final _adeleField203 = switch (_adeleMap201['incompleteReason']) {
    final _adeleNonNullValue213? => _decodeRemoteModelIncompleteReason(
      _adeleNonNullValue213,
    ),
    null => null,
  };
  final _adeleField204 = switch (_adeleMap201['metadata']) {
    final _adeleNonNullValue217? => _decodeRemoteModelTerminalMetadata(
      _adeleNonNullValue217,
    ),
    null => null,
  };
  final _adeleField205 = List<RemoteModelOutput>.unmodifiable(
    _contractList(
      _adeleMap201['output'],
      'output',
    ).map((_adeleElement220) => _decodeRemoteModelOutput(_adeleElement220)),
  );
  final _adeleField206 = switch (_adeleMap201['settlement']) {
    final _adeleNonNullValue225? => _decodeRemoteModelSettlement(
      _adeleNonNullValue225,
    ),
    null => null,
  };
  final _adeleField207 = _contractString(
    _adeleMap201['toolSnapshotHandle'],
    'toolSnapshotHandle',
  );
  return _contractConstruct(
    'RemoteStrategyModelTurn',
    () => RemoteStrategyModelTurn(
      failure: _adeleField202,
      incompleteReason: _adeleField203,
      metadata: _adeleField204,
      output: _adeleField205,
      settlement: _adeleField206,
      toolSnapshotHandle: _adeleField207,
    ),
  );
}

const String remoteSemanticModelInputTypeId = 'orchestration.semanticInput';
Map<String, Object?> _encodeRemoteSemanticModelInput(
  RemoteSemanticModelInput _adeleValue230,
) => <String, Object?>{
  'kind': _adeleValue230.kind.name,
  'payload': _contractJsonMap(_adeleValue230.payload, 'map'),
};
RemoteSemanticModelInput _decodeRemoteSemanticModelInput(
  Object? _adeleValue235,
) {
  final _adeleMap236 = _contractMap(_adeleValue235, 'RemoteSemanticModelInput');
  _contractFields(_adeleMap236, const {
    'kind',
    'payload',
  }, 'RemoteSemanticModelInput');
  final _adeleField237 = _decodeRemoteSemanticModelInputKind(
    _adeleMap236['kind'],
  );
  final _adeleField238 = _contractJsonMap(_adeleMap236['payload'], 'payload');
  return _contractConstruct(
    'RemoteSemanticModelInput',
    () =>
        RemoteSemanticModelInput(kind: _adeleField237, payload: _adeleField238),
  );
}

const String remoteOrchestrationSessionTypeId = 'orchestration.session';
Map<String, Object?> _encodeRemoteOrchestrationSession(
  RemoteOrchestrationSession _adeleValue243,
) => <String, Object?>{
  'sessionId': _adeleValue243.sessionId,
  'strategyId': _adeleValue243.strategyId,
  'taskId': _adeleValue243.taskId,
};
RemoteOrchestrationSession _decodeRemoteOrchestrationSession(
  Object? _adeleValue250,
) {
  final _adeleMap251 = _contractMap(
    _adeleValue250,
    'RemoteOrchestrationSession',
  );
  _contractFields(_adeleMap251, const {
    'sessionId',
    'strategyId',
    'taskId',
  }, 'RemoteOrchestrationSession');
  final _adeleField252 = _contractString(
    _adeleMap251['sessionId'],
    'sessionId',
  );
  final _adeleField253 = _contractString(
    _adeleMap251['strategyId'],
    'strategyId',
  );
  final _adeleField254 = _contractString(_adeleMap251['taskId'], 'taskId');
  return _contractConstruct(
    'RemoteOrchestrationSession',
    () => RemoteOrchestrationSession(
      sessionId: _adeleField252,
      strategyId: _adeleField253,
      taskId: _adeleField254,
    ),
  );
}

const String remoteStrategyToolResultTypeId = 'orchestration.toolResult';
Map<String, Object?> _encodeRemoteStrategyToolResult(
  RemoteStrategyToolResult _adeleValue261,
) => <String, Object?>{
  'item': switch (_adeleValue261.item) {
    final _adeleNonNullValue263? => _encodeRemoteSemanticModelInput(
      _adeleNonNullValue263,
    ),
    null => null,
  },
  'kind': _adeleValue261.kind.name,
};
RemoteStrategyToolResult _decodeRemoteStrategyToolResult(
  Object? _adeleValue268,
) {
  final _adeleMap269 = _contractMap(_adeleValue268, 'RemoteStrategyToolResult');
  _contractFields(_adeleMap269, const {
    'item',
    'kind',
  }, 'RemoteStrategyToolResult');
  final _adeleField270 = switch (_adeleMap269['item']) {
    final _adeleNonNullValue273? => _decodeRemoteSemanticModelInput(
      _adeleNonNullValue273,
    ),
    null => null,
  };
  final _adeleField271 = _decodeRemoteStrategyToolResultKind(
    _adeleMap269['kind'],
  );
  return _contractConstruct(
    'RemoteStrategyToolResult',
    () => RemoteStrategyToolResult(item: _adeleField270, kind: _adeleField271),
  );
}

RemoteModelIncompleteReason _decodeRemoteModelIncompleteReason(
  Object? _adeleValue278,
) {
  if (_adeleValue278 is! String)
    throw AdeleProtocolException('Expected RemoteModelIncompleteReason.');
  return switch (_adeleValue278) {
    'outputLimit' => RemoteModelIncompleteReason.outputLimit,
    'contextLimit' => RemoteModelIncompleteReason.contextLimit,
    'other' => RemoteModelIncompleteReason.other,
    _ => throw AdeleProtocolException(
      'Unknown RemoteModelIncompleteReason: ' + _adeleValue278 + '.',
    ),
  };
}

RemoteModelOutputKind _decodeRemoteModelOutputKind(Object? _adeleValue279) {
  if (_adeleValue279 is! String)
    throw AdeleProtocolException('Expected RemoteModelOutputKind.');
  return switch (_adeleValue279) {
    'providerNative' => RemoteModelOutputKind.providerNative,
    'text' => RemoteModelOutputKind.text,
    'toolProposal' => RemoteModelOutputKind.toolProposal,
    _ => throw AdeleProtocolException(
      'Unknown RemoteModelOutputKind: ' + _adeleValue279 + '.',
    ),
  };
}

RemoteModelSettlement _decodeRemoteModelSettlement(Object? _adeleValue280) {
  if (_adeleValue280 is! String)
    throw AdeleProtocolException('Expected RemoteModelSettlement.');
  return switch (_adeleValue280) {
    'completed' => RemoteModelSettlement.completed,
    'incomplete' => RemoteModelSettlement.incomplete,
    'refused' => RemoteModelSettlement.refused,
    _ => throw AdeleProtocolException(
      'Unknown RemoteModelSettlement: ' + _adeleValue280 + '.',
    ),
  };
}

RemoteRunState _decodeRemoteRunState(Object? _adeleValue281) {
  if (_adeleValue281 is! String)
    throw AdeleProtocolException('Expected RemoteRunState.');
  return switch (_adeleValue281) {
    'created' => RemoteRunState.created,
    'running' => RemoteRunState.running,
    'waiting' => RemoteRunState.waiting,
    'completed' => RemoteRunState.completed,
    'failed' => RemoteRunState.failed,
    'cancelled' => RemoteRunState.cancelled,
    _ => throw AdeleProtocolException(
      'Unknown RemoteRunState: ' + _adeleValue281 + '.',
    ),
  };
}

RemoteRunTransition _decodeRemoteRunTransition(Object? _adeleValue282) {
  if (_adeleValue282 is! String)
    throw AdeleProtocolException('Expected RemoteRunTransition.');
  return switch (_adeleValue282) {
    'start' => RemoteRunTransition.start,
    'complete' => RemoteRunTransition.complete,
    'fail' => RemoteRunTransition.fail,
    _ => throw AdeleProtocolException(
      'Unknown RemoteRunTransition: ' + _adeleValue282 + '.',
    ),
  };
}

RemoteSemanticModelInputKind _decodeRemoteSemanticModelInputKind(
  Object? _adeleValue283,
) {
  if (_adeleValue283 is! String)
    throw AdeleProtocolException('Expected RemoteSemanticModelInputKind.');
  return switch (_adeleValue283) {
    'providerNative' => RemoteSemanticModelInputKind.providerNative,
    'message' => RemoteSemanticModelInputKind.message,
    'toolProposal' => RemoteSemanticModelInputKind.toolProposal,
    'toolProposalFailure' => RemoteSemanticModelInputKind.toolProposalFailure,
    'toolOutcome' => RemoteSemanticModelInputKind.toolOutcome,
    _ => throw AdeleProtocolException(
      'Unknown RemoteSemanticModelInputKind: ' + _adeleValue283 + '.',
    ),
  };
}

RemoteStrategyToolResultKind _decodeRemoteStrategyToolResultKind(
  Object? _adeleValue284,
) {
  if (_adeleValue284 is! String)
    throw AdeleProtocolException('Expected RemoteStrategyToolResultKind.');
  return switch (_adeleValue284) {
    'waiting' => RemoteStrategyToolResultKind.waiting,
    'continuation' => RemoteStrategyToolResultKind.continuation,
    _ => throw AdeleProtocolException(
      'Unknown RemoteStrategyToolResultKind: ' + _adeleValue284 + '.',
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
