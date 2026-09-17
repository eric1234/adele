import 'dart:async';

import 'package:adele_contract/adele_contract.dart';
import 'package:adele_environment/adele_environment.dart';
import 'package:adele_model_tool/adele_model_tool.dart';
import 'package:adele_model_tool/remote_model_tool.dart';
import 'package:adele_plugin_api/adele_plugin_api.dart';
import 'package:adele_product/adele_product.dart';
import 'package:plugin_runtime/plugin_runtime.dart';

/// Adapts transport only; tool multiplicity and collisions remain composer-owned.
final class RemoteModelToolAdapter
    implements RemoteExtensionAdapter<ModelToolContribution> {
  const RemoteModelToolAdapter();

  @override
  ExtensionPoint<ModelToolContribution> get point => modelToolContributions;

  @override
  ModelToolContribution createContribution(RemoteExtensionContext remote) {
    if (remote.exposure.serviceId != remoteModelToolServiceId) {
      throw const ExtensionContractException('Unsupported model-tool service.');
    }
    final metadata = remote.exposure.metadata;
    final services = metadata['hostServices'];
    if (metadata.length != 1 || services is! List<Object?>) {
      throw const ExtensionContractException(
        'Model-tool metadata requires only a hostServices list.',
      );
    }
    if (services.length > 1 ||
        services.any((service) => service != 'authorizedEnvironmentRead')) {
      throw const ExtensionContractException(
        'Unsupported or duplicate model-tool host service.',
      );
    }
    return _RemoteModelTools(remote, requiresRead: services.isNotEmpty);
  }
}

final class _RemoteModelTools implements ModelToolContribution {
  const _RemoteModelTools(this.remote, {required this.requiresRead});

  final RemoteExtensionContext remote;
  final bool requiresRead;

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    remote.validate();
    final files = requiresRead
        ? await context.requireHostService<AuthorizedEnvironmentFileReadFacet>()
        : null;
    if (files != null && files.sessionId != context.sessionId) {
      throw StateError('The filesystem authority belongs to another Session.');
    }
    final binding = _ModelToolBinding(remote, context.sessionId, files);
    final descriptors = await binding.invoke(
      (token) => RemoteModelToolServiceClient(
        remote.channel,
      ).materialize(context.sessionId.value, token),
    );
    return List<ToolRegistration>.unmodifiable([
      for (final descriptor in descriptors)
        ToolRegistration(
          definition: descriptor.toToolDefinition(),
          modelDefinition: descriptor.toModelDefinition(),
          executable: _RemoteToolExecutable(binding, descriptor.routeId),
        ),
    ]);
  }
}

/// Retains host-side authority and the exact extension, never an invocation token.
final class _ModelToolBinding {
  const _ModelToolBinding(this.remote, this.sessionId, this.files);

  final RemoteExtensionContext remote;
  final SessionId sessionId;
  final AuthorizedEnvironmentFileReadFacet? files;

  void validate() {
    try {
      remote.validate();
      files?.validateBinding();
    } on StaleExtensionBinding catch (error) {
      throw StaleToolBindingException(
        'The remote model-tool contributor generation is stale.',
        cause: error,
      );
    } on AuthorizedEnvironmentBindingStale catch (error) {
      throw StaleToolBindingException(error.message, cause: error);
    } on AuthorizedEnvironmentBindingUnavailable catch (error) {
      throw ToolBindingUnavailableException(error.message, cause: error);
    }
  }

  void validateContext(ToolExecutionContext context) {
    validate();
    if (context.sessionId != sessionId) {
      throw StateError('The tool is not authorized for this Session.');
    }
  }

  Future<T> invoke<T>(Future<T> Function(String? token) operation) async {
    validate();
    try {
      if (files == null) return await operation(null);
      final read = _ModelToolEnvironmentRead(this);
      return await remote.invoke(read.services, (invocation) {
        read.invocation = invocation;
        return operation(invocation.id);
      });
    } finally {
      validate();
    }
  }
}

final class _RemoteToolExecutable implements ToolExecutable {
  const _RemoteToolExecutable(this.binding, this.routeId);

  final _ModelToolBinding binding;
  final String routeId;

  RemoteModelToolServiceClient get client =>
      RemoteModelToolServiceClient(binding.remote.channel);

  @override
  void validateBinding() => binding.validate();

  @override
  Future<CanonicalToolArguments> validateAndNormalize(
    Map<String, Object?> proposedArguments,
  ) async {
    validateBinding();
    try {
      // Argument validation has no host context and receives no host authority.
      final result = await client.validateAndNormalize(
        routeId,
        proposedArguments,
      );
      return result.toLocal();
    } on RemoteToolArgumentValidationFailure catch (error) {
      throw ToolArgumentValidationException(error.message);
    } on AdeleProtocolException catch (error) {
      // Protocol exceptions also implement FormatException, but are not a
      // plugin's semantic argument rejection.
      throw PluginRemoteFailure(
        code: 'invalid_response',
        message: error.message,
      );
    } finally {
      validateBinding();
    }
  }

  @override
  Future<EffectDescription> describe(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) {
    binding.validateContext(context);
    return binding.invoke((token) async {
      final result = await client.describe(
        routeId,
        RemoteCanonicalToolArguments(snapshot: arguments.snapshot),
        context.sessionId.value,
        context.runId.value,
        token,
      );
      return result.toLocal();
    });
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) {
    final read = _ModelToolEnvironmentRead(binding);
    return binding.remote
        .invokeStream(read.services, (invocation) {
          binding.validateContext(context);
          read.invocation = invocation;
          return client
              .execute(
                routeId,
                RemoteCanonicalToolArguments(snapshot: arguments.snapshot),
                context.sessionId.value,
                context.runId.value,
                binding.files == null ? null : invocation.id,
              )
              .map((event) {
                validateBinding();
                return event.toLocal();
              })
              .transform(
                StreamTransformer<
                  ToolExecutionEvent,
                  ToolExecutionEvent
                >.fromHandlers(
                  handleDone: (sink) {
                    try {
                      validateBinding();
                    } on Object catch (error, stackTrace) {
                      sink.addError(error, stackTrace);
                    } finally {
                      sink.close();
                    }
                  },
                ),
              );
        })
        .handleError((Object error, StackTrace stackTrace) {
          // Recognize exact binding retirement without relabeling protocol failures.
          validateBinding();
          Error.throwWithStackTrace(error, stackTrace);
        });
  }
}

/// One generated service bound to one operation over previously captured reads.
final class _ModelToolEnvironmentRead
    implements AuthorizedEnvironmentReadService {
  _ModelToolEnvironmentRead(this.binding);

  final _ModelToolBinding binding;
  PluginHostInvocation? invocation;

  Map<String, AdeleBackendDispatcher> get services => {
    if (binding.files != null)
      authorizedEnvironmentReadServiceId:
          AuthorizedEnvironmentReadServiceDispatcher(this),
  };

  void validate() {
    binding.validate();
    if (invocation == null || invocation!.isClosed) {
      throw StateError('The model-tool operation has ended.');
    }
  }

  Future<T> perform<T>(Future<T> Function() operation) async {
    validate();
    try {
      return await operation();
    } finally {
      validate();
    }
  }

  @override
  Future<AuthorizedEnvironmentIdentity> authority() => perform(() async {
    final files = binding.files!;
    return AuthorizedEnvironmentIdentity(
      sessionId: files.sessionId.value,
      environmentId: files.environmentId.value,
    );
  });

  @override
  Future<EnvironmentTextFile> readFile(String relativePath) =>
      perform(() => binding.files!.readFile(relativePath));

  @override
  Future<EnvironmentDirectoryListing> readDirectory(String relativePath) =>
      perform(() => binding.files!.readDirectory(relativePath));
}
