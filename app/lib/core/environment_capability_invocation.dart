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
}) async {
  selection.validate();
  final owner = backends.backendForProvider(selection.binding);
  if (owner == null) {
    throw StateError('The selected provider has no live backend owner.');
  }
  final connection = owner.connection!;
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
    owner.validateProviderOwnership(selection.materialization.binding);
    final associated = owner.associationFor(selection.binding);
    if (!identical(owner.connection, connection) ||
        associated == null ||
        !associated.isSameRegistration(selection.materialization.binding)) {
      throw StateError('The selected provider association is no longer valid.');
    }
  }

  void validateRead() {
    validateSelection();
    if (invocation == null || invocation.isClosed) {
      throw StateError('The contextual read grant has ended.');
    }
  }

  final dispatcher = AuthorizedEnvironmentReadServiceDispatcher(
    _CapturedEnvironmentRead(selection, validateRead),
  );
  try {
    validateSelection();
    detach.add(selection.binding.onRetire(revoke));
    detach.add(selection.materialization.binding.onRetire(revoke));
    detach.add(owner.onRetire(revoke));
    if (onRetire != null) detach.add(onRetire(revoke));
    validateSelection();
    final opened = invocation = connection.openHostInvocation({
      authorizedEnvironmentReadServiceId: dispatcher,
    });
    validateRead();
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
    // Revocation cannot wait for an already-admitted provider read to finish.
    unawaited(dispatcher.close().catchError((Object _) {}));
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
