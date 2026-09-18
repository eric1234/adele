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
    if (services.toSet().length != services.length ||
        services.any((service) => !_knownHostServices.contains(service))) {
      throw const ExtensionContractException(
        'Unsupported or duplicate model-tool host service.',
      );
    }
    return _RemoteModelTools(
      remote,
      Set<String>.unmodifiable(services.cast<String>()),
    );
  }
}

const _knownHostServices = {
  authorizedEnvironmentReadServiceId,
  authorizedEnvironmentMutationServiceId,
  authorizedEnvironmentProcessServiceId,
};

final class _RemoteModelTools implements ModelToolContribution {
  const _RemoteModelTools(this.remote, this.hostServices);

  final RemoteExtensionContext remote;
  final Set<String> hostServices;

  @override
  Future<Iterable<ToolRegistration>> materialize(
    ModelToolHostContext context,
  ) async {
    remote.validate();
    final files = hostServices.contains(authorizedEnvironmentReadServiceId)
        ? await context.requireHostService<AuthorizedEnvironmentFileReadFacet>()
        : null;
    final mutations =
        hostServices.contains(authorizedEnvironmentMutationServiceId)
        ? await context
              .requireHostService<AuthorizedEnvironmentFileMutationFacet>()
        : null;
    final process = hostServices.contains(authorizedEnvironmentProcessServiceId)
        ? await context.requireHostService<AuthorizedEnvironmentProcessFacet>()
        : null;
    final authorities = <AuthorizedEnvironmentAuthority>[
      ?files,
      ?mutations,
      ?process,
    ];
    if (authorities.any(
      (authority) => authority.sessionId != context.sessionId,
    )) {
      throw StateError('The Environment authority belongs to another Session.');
    }
    if (authorities.map((authority) => authority.environmentId).toSet().length >
        1) {
      throw StateError(
        'Read, mutation and process authority must share an Environment.',
      );
    }
    final binding = _ModelToolBinding(
      remote,
      context.sessionId,
      files,
      mutations,
      process,
    );
    // Capturing host dependencies does not grant the backend invocation authority.
    final descriptors = await binding.invoke(
      () => RemoteModelToolServiceClient(
        remote.channel,
      ).materialize(context.sessionId.value),
    );
    for (final descriptor in descriptors) {
      final services = descriptor.executionHostServices;
      if (services.toSet().length != services.length ||
          services.any(
            (service) =>
                !_knownHostServices.contains(service) ||
                !hostServices.contains(service),
          )) {
        throw const ExtensionContractException(
          'Tool execution host services must be unique, known captured dependencies.',
        );
      }
    }
    return List<ToolRegistration>.unmodifiable([
      for (final descriptor in descriptors)
        ToolRegistration(
          definition: descriptor.toToolDefinition(),
          modelDefinition: descriptor.toModelDefinition(),
          executable: _RemoteToolExecutable(binding, descriptor),
        ),
    ]);
  }
}

/// Retains host-side authority and the exact extension, never an invocation token.
final class _ModelToolBinding {
  const _ModelToolBinding(
    this.remote,
    this.sessionId,
    this.files,
    this.mutations,
    this.process,
  );

  final RemoteExtensionContext remote;
  final SessionId sessionId;
  final AuthorizedEnvironmentFileReadFacet? files;
  final AuthorizedEnvironmentFileMutationFacet? mutations;
  final AuthorizedEnvironmentProcessFacet? process;

  EnvironmentId? get environmentId =>
      files?.environmentId ??
      mutations?.environmentId ??
      process?.environmentId;

  void validate() {
    try {
      remote.validate();
      files?.validateBinding();
      mutations?.validateBinding();
      process?.validateBinding();
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

  Future<T> invoke<T>(Future<T> Function() operation) async {
    validate();
    try {
      return await operation();
    } finally {
      validate();
    }
  }
}

final class _RemoteToolExecutable implements ToolExecutable {
  const _RemoteToolExecutable(this.binding, this.descriptor);

  final _ModelToolBinding binding;
  final RemoteToolDescriptor descriptor;

  String get routeId => descriptor.routeId;

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
    return binding.invoke(() async {
      final result = await client.describe(
        routeId,
        RemoteCanonicalToolArguments(snapshot: arguments.snapshot),
        context.sessionId.value,
        context.runId.value,
        binding.environmentId?.value,
      );
      return result.toLocal();
    });
  }

  @override
  Stream<ToolExecutionEvent> execute(
    CanonicalToolArguments arguments,
    ToolExecutionContext context,
  ) async* {
    binding.validateContext(context);
    final environment = _ModelToolEnvironmentServices(binding);
    yield* binding.remote
        .invokeStream(environment.services(descriptor.executionHostServices), (
          invocation,
        ) {
          binding.validateContext(context);
          environment.invocation = invocation;
          return client
              .execute(
                routeId,
                RemoteCanonicalToolArguments(snapshot: arguments.snapshot),
                context.sessionId.value,
                context.runId.value,
                binding.environmentId?.value,
                descriptor.executionHostServices.isEmpty ? null : invocation.id,
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

/// Separate generated dispatchers expose only the exact execute-route allowlist.
final class _ModelToolEnvironmentServices
    implements
        AuthorizedEnvironmentReadService,
        AuthorizedEnvironmentMutationService,
        AuthorizedEnvironmentProcessService {
  _ModelToolEnvironmentServices(this.binding);

  final _ModelToolBinding binding;
  PluginHostInvocation? invocation;

  Map<String, AdeleBackendDispatcher> services(List<String> allowed) => {
    if (allowed.contains(authorizedEnvironmentReadServiceId))
      authorizedEnvironmentReadServiceId:
          AuthorizedEnvironmentReadServiceDispatcher(this),
    if (allowed.contains(authorizedEnvironmentMutationServiceId))
      authorizedEnvironmentMutationServiceId:
          AuthorizedEnvironmentMutationServiceDispatcher(this),
    if (allowed.contains(authorizedEnvironmentProcessServiceId))
      authorizedEnvironmentProcessServiceId:
          AuthorizedEnvironmentProcessServiceDispatcher(this),
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

  @override
  Future<EnvironmentTextFileCreation> createTextFile(
    String relativePath,
    String text,
  ) => perform(() => binding.mutations!.createTextFile(relativePath, text));

  @override
  Future<EnvironmentTextFileReplacement> replaceExistingTextFile(
    String relativePath,
    String replacementText,
    String expectedRevision,
  ) => perform(
    () => binding.mutations!.replaceExistingTextFile(
      relativePath,
      replacementText,
      expectedRevision,
    ),
  );

  @override
  Future<void> deleteExistingTextFile(
    String relativePath,
    String expectedRevision,
  ) => perform(
    () => binding.mutations!.deleteExistingTextFile(
      relativePath,
      expectedRevision,
    ),
  );

  @override
  Stream<EnvironmentProcessEvent> runForegroundProcess(
    EnvironmentForegroundProcessRequest request,
  ) {
    late final StreamController<EnvironmentProcessEvent> controller;
    StreamSubscription<EnvironmentProcessEvent>? subscription;
    Future<void>? cancellation;
    var terminated = false;
    var failed = false;

    Future<void> cancel() {
      terminated = true;
      final current = subscription;
      if (current == null) return Future<void>.value();
      final pending = cancellation ??= Future<void>.sync(current.cancel);
      if (!failed) return pending;
      // Generated dispatch uses cancelOnError; cleanup cannot block its failure.
      unawaited(pending.catchError((Object _) {}));
      return Future<void>.value();
    }

    void fail(Object error, StackTrace stackTrace) {
      if (terminated) return;
      try {
        validate();
      } on Object catch (bindingError, bindingStack) {
        error = bindingError;
        stackTrace = bindingStack;
      }
      failed = true;
      unawaited(cancel());
      controller.addError(error, stackTrace);
      unawaited(controller.close());
    }

    // An idle provider must receive cancellation without waiting for another event.
    controller = StreamController<EnvironmentProcessEvent>(
      sync: true,
      onListen: () {
        try {
          validate();
          subscription = binding.process!
              .runForegroundProcess(request)
              .listen(
                (event) {
                  if (terminated) return;
                  try {
                    validate();
                    controller.add(event);
                  } on Object catch (error, stackTrace) {
                    fail(error, stackTrace);
                  }
                },
                onError: fail,
                onDone: () {
                  if (terminated) return;
                  try {
                    validate();
                    terminated = true;
                    unawaited(controller.close());
                  } on Object catch (error, stackTrace) {
                    fail(error, stackTrace);
                  }
                },
              );
          if (terminated) {
            unawaited(cancel().catchError((Object _) {}));
          } else if (controller.isPaused) {
            subscription!.pause();
          }
        } on Object catch (error, stackTrace) {
          fail(error, stackTrace);
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: cancel,
    );
    return controller.stream;
  }
}
