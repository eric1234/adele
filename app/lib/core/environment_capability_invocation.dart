import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

import 'application_plugin_bootstrap.dart';
import 'environment_capability_selection.dart';

/// Explicit host authorization for one selected unary call, with read access only.
/// The consumer owns its generated client; neither IDs nor payload select authority.
/// [onRetire] optionally observes an additional host-owned lifetime. It must call
/// its listener synchronously on retirement, including when already retired, and
/// return a detach callback. It does not replace exact selection validation.
Future<T> invokeEnvironmentCapabilityWithRead<T>({
  required EnvironmentCapabilitySelection selection,
  required ApplicationPluginBootstrap backends,
  required String serviceId,
  required Future<T> Function(AdeleRequestChannel channel) invoke,
  void Function() Function(void Function())? onRetire,
}) => _invokeEnvironmentCapability(
  selection: selection,
  backends: backends,
  serviceId: serviceId,
  invoke: invoke,
  onRetire: onRetire,
  hostService: AdeleEnvironmentHostService.read,
);

/// Explicit host authorization for a provider-opted-in buffered-process call.
/// Supplies only the buffered-process service, never read or streaming authority.
/// Revocation fences access and publication, not effects already started.
Future<T> invokeEnvironmentCapabilityWithBufferedProcess<T>({
  required EnvironmentCapabilitySelection selection,
  required ApplicationPluginBootstrap backends,
  required String serviceId,
  required Future<T> Function(AdeleRequestChannel channel) invoke,
  void Function() Function(void Function())? onRetire,
}) => _invokeEnvironmentCapability(
  selection: selection,
  backends: backends,
  serviceId: serviceId,
  invoke: invoke,
  onRetire: onRetire,
  hostService: AdeleEnvironmentHostService.bufferedProcess,
);

Future<T> _invokeEnvironmentCapability<T>({
  required EnvironmentCapabilitySelection selection,
  required ApplicationPluginBootstrap backends,
  required String serviceId,
  required Future<T> Function(AdeleRequestChannel channel) invoke,
  required AdeleEnvironmentHostService hostService,
  void Function() Function(void Function())? onRetire,
}) async {
  selection.validate();
  final owner = backends.backendForProvider(selection.binding);
  final environmentOwner = backends.backendForProvider(
    selection.materialization.binding,
  );
  if (owner == null || environmentOwner == null) {
    throw StateError('The selected providers require live backend owners.');
  }
  final connection = owner.connection!;
  final environmentConnection = environmentOwner.connection!;
  final channel = selection.binding.requestChannel;
  if (selection.binding.provider.serviceId != serviceId) {
    throw StateError('The selected provider exposes a different service.');
  }

  var retired = false;
  PluginHostInvocation? invocation;
  final detach = <void Function()>[];
  void revoke() {
    retired = true;
    invocation?.close();
  }

  void validateSelection() {
    if (retired) throw StateError('The contextual operation has retired.');
    selection.validate();
    owner.validateProviderOwnership(selection.binding);
    environmentOwner.validateProviderOwnership(
      selection.materialization.binding,
    );
    if (!identical(owner.connection, connection) ||
        !identical(environmentOwner.connection, environmentConnection)) {
      throw StateError('The selected backend connections are no longer valid.');
    }
    if (hostService == AdeleEnvironmentHostService.bufferedProcess &&
        (!owner.isEnvironmentBound(selection.binding) ||
            !owner.allowsEnvironmentHostService(
              selection.binding,
              hostService,
            ))) {
      throw StateError(
        'The selected provider has no buffered-process permission.',
      );
    }
    if (!owner.isEnvironmentBound(selection.binding)) {
      final associated = owner.associationFor(selection.binding);
      if (!identical(owner, environmentOwner) ||
          associated == null ||
          !associated.isSameRegistration(selection.materialization.binding)) {
        throw StateError(
          'The selected provider association is no longer valid.',
        );
      }
    }
  }

  void validateGrant() {
    validateSelection();
    if (invocation == null || invocation.isClosed) {
      throw StateError('The contextual Environment grant has ended.');
    }
  }

  final AdeleBackendDispatcher dispatcher;
  final String hostServiceId;
  switch (hostService) {
    case AdeleEnvironmentHostService.read:
      hostServiceId = authorizedEnvironmentReadServiceId;
      dispatcher = AuthorizedEnvironmentReadServiceDispatcher(
        _CapturedEnvironmentRead(selection, validateGrant),
      );
    case AdeleEnvironmentHostService.bufferedProcess:
      hostServiceId = authorizedEnvironmentBufferedProcessServiceId;
      dispatcher = AuthorizedEnvironmentBufferedProcessServiceDispatcher(
        _CapturedEnvironmentBufferedProcess(selection, validateGrant),
      );
  }
  try {
    validateSelection();
    detach.add(selection.binding.onRetire(revoke));
    detach.add(selection.materialization.binding.onRetire(revoke));
    detach.add(owner.onRetire(revoke));
    if (!identical(owner, environmentOwner)) {
      detach.add(environmentOwner.onRetire(revoke));
    }
    if (onRetire != null) detach.add(onRetire(revoke));
    validateSelection();
    final opened = invocation = connection.openHostInvocation({
      hostServiceId: dispatcher,
    });
    validateGrant();
    final scoped = connection.bindHostInvocation(
      channel: channel,
      invocation: opened,
      validate: validateSelection,
    );
    final result = await invoke(scoped);
    validateSelection();
    return result;
  } finally {
    revoke();
    for (final remove in detach.reversed) {
      remove();
    }
    // Revocation cannot wait for, cancel, or undo an admitted provider operation.
    unawaited(dispatcher.close().catchError((Object _) {}));
  }
}

final class _CapturedEnvironmentBufferedProcess
    implements AuthorizedEnvironmentBufferedProcessService {
  _CapturedEnvironmentBufferedProcess(this.selection, this.validate);

  final EnvironmentCapabilitySelection selection;
  final void Function() validate;

  @override
  Future<AuthorizedEnvironmentIdentity> capturedIdentity() async {
    validate();
    return AuthorizedEnvironmentIdentity(
      sessionId: selection.session.id.value,
      environmentId: selection.environment.id.value,
    );
  }

  @override
  Future<EnvironmentBufferedProcessResult> runBufferedProcess(
    EnvironmentBufferedProcessRequest request,
  ) async {
    validate();
    final provider = selection.materialization.provider;
    if (provider is! EnvironmentBufferedProcessProvider) {
      throw const EnvironmentFailure(
        code: environmentBufferedProcessUnavailableCode,
        message:
            'This Environment provider does not support buffered processes.',
        details: <String, Object?>{},
      );
    }
    try {
      return await (provider as EnvironmentBufferedProcessProvider)
          .runBufferedProcess(selection.environment.id, request);
    } finally {
      validate();
    }
  }
}

/// Reads use the very materialization that established eligibility, never a
/// second Session lookup or a provider selected from a transported identity.
final class _CapturedEnvironmentRead
    implements AuthorizedEnvironmentReadService {
  _CapturedEnvironmentRead(this.selection, this.validate);

  final EnvironmentCapabilitySelection selection;
  final void Function() validate;

  @override
  Future<AuthorizedEnvironmentIdentity> authority() async {
    validate();
    return AuthorizedEnvironmentIdentity(
      sessionId: selection.session.id.value,
      environmentId: selection.environment.id.value,
    );
  }

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) async {
    validate();
    try {
      return await selection.materialization.provider.readFile(
        selection.environment.id,
        relativePath,
      );
    } finally {
      validate();
    }
  }

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) async {
    validate();
    try {
      return await selection.materialization.provider.readDirectory(
        selection.environment.id,
        relativePath,
      );
    } finally {
      validate();
    }
  }
}
